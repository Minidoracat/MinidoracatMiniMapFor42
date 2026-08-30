-- MinidoracatMiniMap_Dots.lua
-- 本檔範圍：殭屍點雲＋動物/載具圖標的「取樣＋繪製」（小地圖與世界地圖共用）。
-- 拆檔緣由：主檔主 chunk 累計 local 頂到 Kahlua 上限 200（LexState actvar[200]
-- 固定陣列；-debug 下 actvarline 以累計 nlocvars 索引，第 201 個宣告即
-- ArrayIndexOutOfBounds，遊戲內實爆記錄 2026-08-20）——luac -p 抓不到
-- （PUC 檢查的是同時活躍數），守衛見 scripts/verify_mod.py 的 main-chunk
-- locals 檢查。點雲段內聚性最高、依賴面全可經 Core.* 取得，故整段遷出。
-- 註冊表與公開 API 留主檔（ADOTS_ART/SPECIES_UI/VEHCAT_UI/COLOR_ITEMS/
-- registerAnimalGroup/adotsTexture——載入期即需存在、_Settings 與 compat
-- addon 經命名空間引用）；deriveAffine/visibleWorldAABB/unifiedCsvSet 為
-- zone/POI 跨段共用，同樣留主檔經 Core 取。
-- 出處註解沿用主檔原文（42.20.2/42.20.3 反編譯行號）。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

-- 主檔資源（載入期取一次：主檔字母序先載完，Core.* 已全數就緒；modOptions
-- 可為 nil＝無 PZAPI，下方各處沿用原 nil 檢查）
local modOptions = Core.modOptions
local getBoolOption = Core.getBoolOption
local getComboIndex = Core.getComboIndex
local getSliderValue = Core.getSliderValue
local sandboxGate = Core.sandboxGate
local displayDist = Core.displayDist
local livestockVisibilityMode = Core.livestockVisibilityMode
local unifiedCsvSet = Core.unifiedCsvSet
local visibleWorldAABB = Core.visibleWorldAABB
local deriveAffine = Core.deriveAffine
local adotsTexture = Core.adotsTexture
local ADOTS_ART = Core.ADOTS_ART
local ADOTS_SPECIES_UI = Core.ADOTS_SPECIES_UI
local ADOTS_VEHCAT_UI = Core.ADOTS_VEHCAT_UI
local ADOTS_FALLBACK_SYM = Core.ADOTS_FALLBACK_SYM

local function log(msg)
    print("[MinidoracatMiniMap] " .. msg)
end

--------------------------------------------------------------------------------
-- 精準殭屍圖標（ZombieDots，預設關）
-- 資料源：getCell():getZombieList()——getCell＝LuaManager.java:5666、
-- IsoCell.getZombieList＝IsoCell.java:2658（已載入殭屍的 ArrayList）、
-- IsoCell/IsoZombie 已 exposed 給 Lua＝LuaManager.java:2147/1807。
-- 效能設計（B41 同類功能卡頓根因＝無節流自繪，本功能靈魂在此）：
--   取樣每 ZDOTS_INTERVAL_MS 一次（getTimestampMs＝LuaManager.java:9317，
--   用例 ISChat.lua:469）、上限 ZDOTS_MAX 隻、只抄 (x,y) 進重用的 table 池，
--   不持有殭屍物件引用；開關關閉時不取樣不繪製（零成本）。
-- 繪製掛 ISMiniMapInner:prerender（主檔 wrap 經 Core 呼叫）：UIWorldMap.java:152
-- render 先畫地圖本體、行 317 才 super.render() → UIElement.java:1594 呼叫 Lua
-- prerender，故點位畫在地圖之上、齒輪面板（inner 子元件，1604 子元件迴圈較晚畫）
-- 之下。世界地圖（M 鍵）亦可畫（WM* 獨立開關）——客戶端只知道已載入個體，
-- 拉遠不會鋪滿全圖。
--------------------------------------------------------------------------------
local ZDOTS_INTERVAL_MS = 300 -- 取樣間隔（毫秒）
local ZDOTS_MAX = 200         -- 單次取樣殭屍數上限
-- 顏色／大小查表（索引＝ModOptions combobox 項次，繪製端每幀讀值即時生效）。
-- 預設亮橘＝與原版純紅 6×6 玩家點（UIWorldMap.java:218 本地、:493 遠端）錯開色相；
-- 黑描邊讓小點在草地／道路／屋頂任何底色上都跳得出來；紅色項留給不需區分者。
local ZDOTS_COLORS = {
    { 1.0, 0.62, 0.05 }, -- 橘（預設）
    { 1.0, 0.9,  0.1  }, -- 黃
    { 0.8, 0.35, 1.0  }, -- 紫
    { 1.0, 1.0,  1.0  }, -- 白
    { 1.0, 0.0,  0.0  }, -- 紅
}
-- （舊三檔大小 combobox 的像素換算表已隨遷移程式碼移至 MinidoracatMiniMap_Migrate.lua）
local ZDOTS_MAXES = { 100, 200, 400, 800 } -- 上限檔位（索引對應 ZombieDotMax combobox）
local ZDOTS_A = 1.0
local ZDOTS_EDGE_A = 0.8      -- 描邊透明度（黑）；隨 ZombieDotAlpha 滑條等比縮放

-- ponytail: 掃描硬上限 4000——超過的清單尾端不掃（輪替起點掃描是升級路徑），
-- 實務上客戶端同步的殭屍數遠低於此，引擎也早在此之前就跑不動了
local ZDOTS_SCAN_MAX = 4000
-- 距離分層優先：視窗內殭屍數超過上限時，額度先給離玩家近的
-- （近圈→中圈→遠圈三桶，單次掃描免排序；桶各自封頂 maxDots，記憶體有界）
local ZDOTS_NEAR = 30 -- 近圈半徑（世界格）
local ZDOTS_MID = 80  -- 中圈半徑

-- 取樣狀態掛在地圖元件上（分割畫面各玩家、以及同玩家的「小地圖／世界地圖」
-- 兩個表面各自持有——按 playerNum 分槽會讓兩表面互搶點池與節流、視窗範圍
-- 不同會畫錯）；元件重建＝狀態自然重置，池重用不產生每幀垃圾
local function zdotsStateFor(el)
    local st = el._minidoracatZDots
    if not st then
        st = { dots = {}, near = {}, mid = {}, far = {}, count = 0, nextMs = 0 }
        el._minidoracatZDots = st
    end
    -- 世界地圖是 singleton：關閉只隱藏（ISWorldMap.lua:1157 setVisible(false)）、
    -- 再開改寫 playerNum 重用同物件（:1547-1550）——換擁有者即重置，
    -- 分割畫面不沿用前一位的點池
    local pn = el.playerNum or 0
    if st.owner ~= pn then
        st.owner = pn
        st.count = 0
        st.nextMs = 0
        st.hasPlayer = nil
        st.failOnce = nil
    end
    return st
end

-- test:zombie-sampling:start
local function sampleZombieDots(inner)
    local pn = inner.playerNum or 0
    local st = zdotsStateFor(inner)
    local dist = displayDist("ZombieDotDistance", pn)
    local now = getTimestampMs()
    local playerObj = getSpecificPlayer(pn)
    local hasPlayer = playerObj ~= nil
    if now < st.nextMs and st.distance == dist and st.hasPlayer == hasPlayer then return st end
    st.distance = dist
    st.hasPlayer = hasPlayer
    st.nextMs = now + ZDOTS_INTERVAL_MS
    st.count = 0
    -- 距離閘門啟用時缺玩家物件必須 fail closed；先於 mapAPI/list 存取，兼顧 teardown。
    if dist and not playerObj then return st end
    local cell = getCell()
    local list = cell and cell:getZombieList()
    if not list then return st end
    -- 只收「小地圖可視範圍內」的殭屍再套 ZDOTS_MAX：getZombieList 的順序是
    -- 載入序而非距離序，早期版本取「清單前 N 隻」會被別處先生成的大群吃光
    -- 名額，玩家身邊的反而畫不出來（實測：管理員刷群後即重現）。
    local minX, maxX, minY, maxY = visibleWorldAABB(inner)
    -- 仿射錨點＝取樣時的視野中心（供繪製端 deriveAffine 用）：錨定視野中心使
    -- 最壞偏移距離＝半個視野跨度（錨定首點是全跨度、float32 係數誤差×距離會
    -- 放大一倍——世界地圖全圖縮放下可差 px 級）；x-x%1 即 floor（座標恆正）
    local sacx = (minX + maxX) / 2
    local sacy = (minY + maxY) / 2
    st.acx = sacx - sacx % 1
    st.acy = sacy - sacy % 1
    -- 上限檔位每輪讀值（ZombieDotMax combobox），存檔即生效
    local maxDots = ZDOTS_MAXES[getComboIndex("ZombieDotMax", 2)] or ZDOTS_MAX
    -- 距離基準＝玩家位置（自由查看拖走視窗也以「離自己」為優先，符合直覺）；
    -- getSpecificPlayer/getX/getY 原版用例 ISMiniMap.lua:216-222；未啟用距離閘門且
    -- 缺玩家時沿用舊行為退回視窗中心
    local px = playerObj and playerObj:getX() or ((minX + maxX) / 2)
    local py = playerObj and playerObj:getY() or ((minY + maxY) / 2)
    local dist2 = dist and dist * dist
    local near2 = ZDOTS_NEAR * ZDOTS_NEAR
    local mid2 = ZDOTS_MID * ZDOTS_MID
    -- pcall 防競態：getZombieList 是模擬端會增刪的活 ArrayList，size 與 get
    -- 之間殭屍被移除會丟 IndexOutOfBounds——失敗就放棄本輪取樣（300ms 後重試）
    local ok, err = pcall(function()
        local n = list:size()
        if n > ZDOTS_SCAN_MAX then n = ZDOTS_SCAN_MAX end
        local nearC, midC, farC = 0, 0, 0
        for i = 1, n do
            local z = list:get(i - 1)
            local zx, zy = z:getX(), z:getY()
            if zx >= minX and zx <= maxX and zy >= minY and zy <= maxY then
                local ddx, ddy = zx - px, zy - py
                local d2 = ddx * ddx + ddy * ddy
                if not dist2 or d2 <= dist2 then
                    local pool, c
                    if d2 <= near2 then
                        if nearC < maxDots then nearC = nearC + 1; pool = st.near; c = nearC end
                    elseif d2 <= mid2 then
                        if midC < maxDots then midC = midC + 1; pool = st.mid; c = midC end
                    else
                        if farC < maxDots then farC = farC + 1; pool = st.far; c = farC end
                    end
                    if pool then
                        local d = pool[c]
                        if not d then d = {}; pool[c] = d end
                        d.x = zx
                        d.y = zy
                    end
                end
                if nearC >= maxDots then break end -- 近圈吃滿額度＝後面必不入選
            end
        end
        -- 合併：近→中→遠 依序填滿 maxDots（近的永遠優先於遠的）
        local count = 0
        local function take(pool, c)
            for j = 1, c do
                if count >= maxDots then return end
                count = count + 1
                local s = st.dots[count]
                if not s then s = {}; st.dots[count] = s end
                s.x = pool[j].x
                s.y = pool[j].y
            end
        end
        take(st.near, nearC)
        take(st.mid, midC)
        take(st.far, farC)
        st.count = count
    end)
    if not ok then
        st.count = 0
        -- pcall 防的是活清單競態（暫時性，下輪取樣自癒）；持久性錯誤（API 漂移）
        -- 不能全靜默——每表面 log 一次留診斷線索（同動物取樣 failOnce 慣例）
        if not st.failOnce then
            st.failOnce = true
            log("zombie sampling failed (logged once per surface): " .. tostring(err))
        end
    end
    return st
end
-- test:zombie-sampling:end

-- 殭屍點繪製（小地圖與世界地圖共用；el 需有 mapAPI/width/height/playerNum）。
-- optId＝該表面的開關（小地圖 ZombieDots／世界地圖 WMZombieDots）；
-- 顏色/大小/上限與伺服器沙盒閘兩表面共用
local function drawZombieDotsOn(el, optId)
    if not getBoolOption(optId, false) then return end -- 關閉＝零成本
    -- 伺服器沙盒禁用（管理員戰術檢視生效時 Policy 對此鍵回 true＝旁路）：
    -- 兩表面共用同一判定，pn 取該表面目前的擁有者（世界地圖 singleton 會換人）
    if sandboxGate("AllowZombieDots", true, el.playerNum or 0) == false then return end
    local st = sampleZombieDots(el)
    local c = ZDOTS_COLORS[getComboIndex("ZombieDotColor", 1)] or ZDOTS_COLORS[1]
    local size = getSliderValue("ZombieDotSize", 3, 1, 16)
    local af = getSliderValue("ZombieDotAlpha", 100, 10, 100) / 100 -- 透明度係數（描邊/本體等比）
    local mapAPI = el.mapAPI
    -- 仿射投影（perf 稽核 ICON-1）：原每點 2 次 worldToUI 跨界（800 檔＝1600 次/
    -- 幀/表面）收斂為每幀 6 次導係數採樣＋逐點純 Lua 乘加。錨定取樣時的視野
    -- 中心（st.acx，最壞偏移＝半個視野跨度；首點 fallback 給無此欄的舊狀態）——
    -- 避開 float32 遠錨消去（deriveAffine 註解）；純度假設與 zone 三 pass 同一份。
    -- worldToUIX/Y＝UIWorldMapV1.java:298/311
    if st.count > 0 then
        local d1 = st.dots[1]
        local acx = st.acx or (d1.x - d1.x % 1)
        local acy = st.acy or (d1.y - d1.y % 1)
        local p0x, p0y, sxx, sxy, syx, syy = deriveAffine(mapAPI, acx, acy)
        for i = 1, st.count do
            local d = st.dots[i]
            local dx, dy = d.x - acx, d.y - acy
            local ux = p0x + dx * sxx + dy * syx
            local uy = p0y + dx * sxy + dy * syy
            -- 手動裁到視窗內（Lua drawRect 不吃元件裁切）；含描邊起繪於 ux-2。
            -- drawRect＝ISUIElement.lua:1191（引數 x,y,w,h,a,r,g,b）
            if ux >= 2 and uy >= 2 and ux <= el.width - size and uy <= el.height - size then
                el:drawRect(ux - 2, uy - 2, size + 2, size + 2, ZDOTS_EDGE_A * af, 0, 0, 0)
                el:drawRect(ux - 1, uy - 1, size, size, ZDOTS_A * af, c[1], c[2], c[3])
            end
        end
    end
end

--------------------------------------------------------------------------------
-- 動物圖標（AnimalDots，預設關）：野生/畜養獨立開關＋兩種圖標風格。
-- 資料源：getCell():getAnimals()（IsoCell.java:4533——Java 端過濾 objectList
-- 回傳新 LinkedList；IsoCell/IsoAnimal 已 exposed＝LuaManager.java:2147/1785）。
-- 與殭屍清單不同：這是每呼叫新建的快照（非活 ArrayList），成本在建表——
-- 取樣節流是必要而非優化；動物數量級低（數十），免殭屍側的距離分桶。
-- 物種歸併：getAnimalType()（IsoAnimal.java:1608）回 stage 級 key（hen/chick…），
-- 以 Lua 全域表 AnimalDefinitions.animals[type].group 併成 10 物種
-- （shared/Definitions/animal/*.lua；Java 讀同表＝AnimalDefinitions.java:176-183）。
-- 圖標素材（皆遊戲內建，零自帶資產）：
--   符號風格＝原版地圖符號（MapSymbolDefinitions.lua:60-71 註冊的
--   media/ui/LootableMaps/map_*.png，白 glyph→乘法染色：白=畜養、綠=野生）；
--   物品風格＝物品欄彩圖（getTexture("Item_X") 無路徑寫法用例 ISHutchUI.lua:95）。
-- getTexture 走引擎共享快取（Texture.java:482-484），本地再快取一層免每幀 hash。
--------------------------------------------------------------------------------
local ADOTS_INTERVAL_MS = 500 -- 動物移動慢，刷新率要求低於殭屍的 300ms
local ADOTS_MAX = 100         -- 視窗內同時顯示上限（動物+載具合計，防禦性封頂）
local ADOTS_SCAN_MAX = 500    -- 清單掃描硬上限（LinkedList get(i) 為 O(n)，防病態存檔）
-- （舊三檔大小 combobox 的像素換算表已隨遷移程式碼移至 MinidoracatMiniMap_Migrate.lua；
-- 0.9.0 起大小由玩家滑條直接指定像素，物品風格不再整表放大）
-- 圖標染色盤：索引對應 ADOTS_COLOR_ITEMS（主檔選項註冊區）順序，兩表必須同步。
-- Okabe-Ito 色盲友善色系；綠/天藍沿用實測亮度（乘法染色在深色地圖需偏亮 tint）
local ADOTS_PALETTE = {
    { 1.0, 1.0, 1.0 },    -- 白
    { 0.47, 0.88, 0.37 }, -- 綠（現行野生色）
    { 0.90, 0.62, 0.0 },  -- 橘（#E69F00）
    { 0.45, 0.8, 1.0 },   -- 天藍（現行載具色）
    { 0.94, 0.89, 0.26 }, -- 黃（#F0E442）
    { 0.86, 0.52, 0.70 }, -- 紫紅（#CC79A7 提亮）
    { 0.20, 0.55, 0.85 }, -- 藍（#0072B2 提亮）
    { 0.90, 0.42, 0.10 }, -- 硃紅（#D55E00 提亮）
}
local function adotsColor(optId, default)
    return ADOTS_PALETTE[getComboIndex(optId, default)] or ADOTS_PALETTE[default]
end
-- 載具：內建無車形地圖圖示（LootableMaps 92 張與 MapSymbolDefinitions 皆無 car），
-- 取最接近的原版符號「方向盤」（顏色由 VehicleIconColor 下拉決定，預設天藍）
local ADOTS_VEH_SYM = "media/ui/LootableMaps/map_steeringwheel.png"

-- 篩選讀取（sampler 每輪呼叫；以原始字串為 key 快取解析結果）。
-- 回傳「停用 group 集合」與原始字串（原始字串併入取樣 cache key）
local adotsFilterCaches = {} -- [optId] = { raw, groups }
local function adotsDisabledGroups(optId, uiDefs)
    if not modOptions then return nil, "" end
    local opt = modOptions:getOption(optId)
    if not opt then return nil, "" end
    local raw = tostring(opt:getValue() or "")
    local c = adotsFilterCaches[optId]
    if not c or c.raw ~= raw then
        local dis = unifiedCsvSet(raw)
        local groups = {}
        for i = 1, #uiDefs do
            local def = uiDefs[i]
            if dis[def.key] then
                if def.groups then
                    for j = 1, #def.groups do groups[def.groups[j]] = true end
                else
                    groups[def.key] = true
                end
            end
        end
        c = { raw = raw, groups = groups }
        adotsFilterCaches[optId] = c
    end
    return c.groups, raw
end

local adotsGroupCache = {} -- [animalType] = 物種 group 字串
local function adotsGroup(atype)
    if atype == nil then return "unknown" end -- 載入前窗口 type 可為空；nil 鍵入快取的保險
    local g = adotsGroupCache[atype]
    if g == nil then
        local defs = AnimalDefinitions and AnimalDefinitions.animals
        local def = defs and defs[atype]
        g = (def and def.group) or "unknown"
        adotsGroupCache[atype] = g
    end
    return g
end

-- 牲畜歸屬只能用所在安全屋代理：動物與畜養區（DesignationZoneAnimal.java
-- 全檔無 owner 欄位）都沒有持久化的玩家擁有者資料。成員判定同 drawSafehouses
-- （String 版 playerAllowed，SafeHouse.java:290-292）。
-- 每輪取樣先抽成純 Lua 表：每動物重掃 Java 清單是 O(動物×安全屋) 跨界呼叫、
-- 病態 MP 配置（50 屋×30 牲畜）有取樣幀尖峰；抽表後內迴圈是純 Lua 數值比較
-- （drawSafehouses 逐幀重讀是畫框所需，這裡 500ms 一次快照即可）
local function adotsSafehouseRects(username)
    if not (SafeHouse and SafeHouse.getSafehouseList) then return nil end
    local list = SafeHouse.getSafehouseList()
    if not list then return nil end
    local rects = {}
    for i = 0, list:size() - 1 do
        local sh = list:get(i)
        rects[i + 1] = { x1 = sh:getX(), y1 = sh:getY(), x2 = sh:getX2(), y2 = sh:getY2(),
            allowed = username ~= nil and username ~= "" and sh:playerAllowed(username) }
    end
    return rects
end

-- 含界判定照原版半開區間（containsLocation＝SafeHouse.java:636-638：>= x1 且 < x2），
-- 用 <= 會把剛好在東/南界外一格的牲畜誤隱藏。
-- nil rects＝SafeHouse API/清單或玩家身分不可用；模式 2/3 一律 fail closed。
-- 有效空清單則不同：模式 2 顯示安全屋外牲畜，模式 3 全隱藏。
-- 注意這是「顯示層政策」非防作弊：修改過的客戶端仍讀得到已同步資料。
-- test:livestock-visibility:start
local function adotsLivestockVisible(ax, ay, mode, rects)
    if mode == 1 then return true end
    if mode == 4 or rects == nil then return false end
    for i = 1, #rects do
        local r = rects[i]
        if ax >= r.x1 and ax < r.x2 and ay >= r.y1 and ay < r.y2 then
            return r.allowed
        end
    end
    return mode == 2
end
-- test:livestock-visibility:end

-- 載具分類：警燈車（警/消/救，橫跨 mechanicType 1/3）優先判特勤——
-- hasLightbar＝BaseVehicle.java:9107（script.getLightbar().enable）；
-- 其餘依 VehicleScript.getMechanicType（:1942；腳本值對照 media/scripts/generated/
-- vehicles/**：皮卡/廂型=2、luxury/警用跑車=3、一般=1）
local function adotsVehCategory(v)
    -- 先取 script 判 nil 再問警燈：hasLightbar 直接解參考 script
    -- （BaseVehicle.java:9107），而 script==null 是引擎承認的運行態
    -- （原版多處自防，如 BaseVehicle.java:6511）——不防會 NPE 廢掉整輪取樣
    local script = v:getScript()
    if not script then return "standard" end
    if v:hasLightbar() then return "special" end
    local mt = script:getMechanicType() or 1
    if mt == 2 then return "heavy" end
    if mt == 3 then return "sport" end
    return "standard"
end

-- 取樣狀態掛在地圖元件上（分槽理由同 zdotsStateFor：兩表面/分割畫面各自持有）
-- test:animal-sampling:start
local function sampleAnimalDots(inner, wantWild, wantLive, wantVeh)
    local pn = inner.playerNum or 0
    local st = inner._minidoracatADots
    if not st then
        st = { dots = {}, count = 0, nextMs = 0 }
        inner._minidoracatADots = st
    end
    -- 世界地圖 singleton 換擁有者重置（同 zdotsStateFor 註解）：點池、節流、
    -- cache key 與 log-once 旗標都不跨玩家沿用——牲畜隱私過濾按各自身分重算
    if st.owner ~= pn then
        st.owner = pn
        st.count = 0
        st.nextMs = 0
        st.mask = nil
        st.da = nil
        st.dv = nil
        st.rawA = nil
        st.rawV = nil
        st.mode = nil
        st.errLogged = nil
    end
    local now = getTimestampMs()
    local da = displayDist("AnimalIconDistance", pn)
    local dv = displayDist("VehicleIconDistance", pn)
    local livestockMode = livestockVisibilityMode(pn)
    -- cache key 逐欄位比較（perf 稽核 ICON-3，殭屍側 st.distance 既有寫法）：
    -- 原每幀組 flags 字串（5 次 tostring＋串接）＝穩定的 GC churn 來源。開關組合
    -- ＋篩選逐欄入 key：節流窗內任一變了就立即重取樣，否則剛關掉的類別/物種會
    -- 殘留舊點池最多 500ms。篩選欄位是自由文字，等值比較無碰撞問題
    local disAnimal, rawA = adotsDisabledGroups("AnimalSpeciesFilter", ADOTS_SPECIES_UI)
    local disVeh, rawV = adotsDisabledGroups("VehicleCategoryFilter", ADOTS_VEHCAT_UI)
    local mask = (wantWild and 1 or 0) + (wantLive and 2 or 0) + (wantVeh and 4 or 0)
    -- username/hasPlayer 留在節流 key（牲畜隱私過濾與 fail closed 的既有契約：
    -- 變更須「立即」淘汰快取，test_livestock_visibility 鎖此行為，不得延後）；
    -- getSpecificPlayer/getUsername 原版用例 ISMiniMap.lua:216-222／ISScoreboard.lua:108
    local playerObj = getSpecificPlayer(pn)
    local username = playerObj and playerObj:getUsername()
    local hasPlayer = playerObj ~= nil
    if now < st.nextMs and st.mask == mask and st.da == da and st.dv == dv
        and st.rawA == rawA and st.rawV == rawV and st.mode == livestockMode
        and st.username == username and st.hasPlayer == hasPlayer then
        return st
    end
    -- 座標 getter 延後到節流通過後（ICON-3）：px/py 僅重取樣的距離閘用，
    -- 節流命中的 29/30 幀原本白付 2 次跨界
    local px = playerObj and playerObj:getX()
    local py = playerObj and playerObj:getY()
    st.mask = mask
    st.da = da
    st.dv = dv
    st.rawA = rawA
    st.rawV = rawV
    st.mode = livestockMode
    st.username = username
    st.hasPlayer = hasPlayer
    st.nextMs = now + ADOTS_INTERVAL_MS
    st.count = 0
    local cell = getCell()
    if not cell then return st end
    local minX, maxX, minY, maxY = visibleWorldAABB(inner) -- 可視框剔除（同殭屍取樣）
    -- 仿射錨點＝取樣時的視野中心（理由同殭屍取樣的 st.acx 註解）
    local sacx = (minX + maxX) / 2
    local sacy = (minY + maxY) / 2
    st.acx = sacx - sacx % 1
    st.acy = sacy - sacy % 1
    -- 距離啟用但缺玩家時，對應動物或載具類別 fail closed
    local da2 = da and da * da
    local dv2 = dv and dv * dv
    -- 點池欄位每次全量覆寫（含 veh 旗標）——池重用會殘留上一輪欄位
    local function push(x, y, veh, wild, group)
        local c = st.count + 1
        st.count = c
        local d = st.dots[c]
        if not d then d = {}; st.dots[c] = d end
        d.x = x
        d.y = y
        d.veh = veh
        d.wild = wild
        d.group = group
        return c >= ADOTS_MAX
    end
    -- pcall 防競態：清單雖是快照，元素仍是活物件（isDead/getX 期間可能被模擬端移除）。
    -- 動物/載具各自一個 failure boundary：第三方動物資料出錯不連坐清空載具
    -- （反之亦然）；失敗保留該輪已 push 的部分結果。首錯記 log 一次
    -- （取樣層最可能出錯：第三方資料/API 漂移，broad catch 不能全靜默）
    local function failOnce(err)
        if not st.errLogged then
            st.errLogged = true
            log("animal/vehicle sampling failed: " .. tostring(err))
        end
    end
    if (wantWild or (wantLive and livestockMode ~= 4)) and (not da or playerObj ~= nil) then
        local ok, err = pcall(function()
            local list = cell:getAnimals()
            local shRects
            if wantLive and (livestockMode == 2 or livestockMode == 3)
                and username ~= nil and username ~= "" then
                shRects = adotsSafehouseRects(username)
            end
            local n = list and list:size() or 0
            if n > ADOTS_SCAN_MAX then n = ADOTS_SCAN_MAX end
            for i = 1, n do
                local a = list:get(i - 1)
                local ax, ay = a:getX(), a:getY()
                local inDistance = not da2
                    or (ax - px) * (ax - px) + (ay - py) * (ay - py) <= da2
                -- isDead＝IsoGameCharacter.java:4896（死亡動物屍體不畫）
                if ax >= minX and ax <= maxX and ay >= minY and ay <= maxY
                    and inDistance and not a:isDead() then
                    local wild = a:isWild() -- IsoAnimal.java:3222
                    local show = wild and wantWild
                    if not wild then
                        show = wantLive and adotsLivestockVisible(ax, ay, livestockMode, shRects)
                    end
                    if show then
                        local group = adotsGroup(a:getAnimalType())
                        if not (disAnimal and disAnimal[group]) then -- 物種篩選
                            if push(ax, ay, false, wild, group) then break end
                        end
                    end
                end
            end
        end)
        if not ok then failOnce(err) end
    end
    -- 載具：getVehicles() 回 HashSet（IsoCell.java:155/2698）——沒有 get(i)，
    -- ISVehicleBloodUI.lua:80-82 的 get 寫法是原版冷門路徑的雷、勿仿；
    -- 以 :toArray()＋ipairs 迭代（原版用例 Vehicles.lua:1038）
    if wantVeh and st.count < ADOTS_MAX and (not dv or playerObj ~= nil) then
        local ok, err = pcall(function()
            local vlist = cell:getVehicles()
            local varr = vlist and vlist:toArray()
            if varr then
                local scanned = 0
                for _, v in ipairs(varr) do
                    scanned = scanned + 1
                    if scanned > ADOTS_SCAN_MAX then break end
                    local vx, vy = v:getX(), v:getY()
                    local inDistance = not dv2
                        or (vx - px) * (vx - px) + (vy - py) * (vy - py) <= dv2
                    if vx >= minX and vx <= maxX and vy >= minY and vy <= maxY
                        and inDistance then
                        if not (disVeh and disVeh[adotsVehCategory(v)]) then -- 類別篩選
                            if push(vx, vy, true, false, nil) then break end
                        end
                    end
                end
            end
        end)
        if not ok then failOnce(err) end
    end
    return st
end
-- test:animal-sampling:end

-- 繪製（prerender wrap 內呼叫）：
--   符號風格＝黑影四斜角偏移＋染色本體疊繪兩次（白 glyph 線條細、單次繪 alpha 偏淡，
--   疊繪增濃；疊繪次數是實測調校旋鈕）——drawTextureScaled 引數 (tex,x,y,w,h,a,r,g,b)，
--   主檔標題列 wrap 與 ISCollapsableWindow.lua:160 同序；
--   物品風格＝黑底方塊（drawRect）＋原色彩圖＋野生綠角標。
-- 白 glyph 繪製：黑影四斜角＋染色本體疊繪兩次（白 glyph 線條細、單次繪 alpha 偏淡，
-- 疊繪增濃；次數是實測調校旋鈕）——動物符號風格與載具共用
local adotsBodyACache = {} -- af→bodyA（ICON-4：sqrt 是跨界呼叫、原每圖標每幀一次；af 來自滑條離散值，鍵集有界）
local function adotsDrawGlyph(inner, tex, ux, uy, size, r, g, b, af)
    af = af or 1 -- 透明度係數（黑影/本體等比；呼叫端可省略）
    -- 本體疊繪兩次（增濃細線 glyph）：兩 pass 標準 alpha 合成為 1-(1-x)^2，
    -- 每 pass 直接用 af 會偏濃（50%→實得 75%，codex review 抓出）——
    -- 反解每 pass alpha 使合成恰等於滑條百分比；af=1 時 bodyA=1＝現行外觀不變
    local bodyA = af >= 1 and 1 or adotsBodyACache[af]
    if not bodyA then
        bodyA = 1 - math.sqrt(1 - af)
        adotsBodyACache[af] = bodyA
    end
    inner:drawTextureScaled(tex, ux - 1, uy - 1, size, size, 0.85 * af, 0, 0, 0)
    inner:drawTextureScaled(tex, ux + 1, uy - 1, size, size, 0.85 * af, 0, 0, 0)
    inner:drawTextureScaled(tex, ux - 1, uy + 1, size, size, 0.85 * af, 0, 0, 0)
    inner:drawTextureScaled(tex, ux + 1, uy + 1, size, size, 0.85 * af, 0, 0, 0)
    inner:drawTextureScaled(tex, ux, uy, size, size, bodyA, r, g, b)
    inner:drawTextureScaled(tex, ux, uy, size, size, bodyA, r, g, b)
end

-- wildOpt/liveOpt/vehOpt＝該表面的開關選項（小地圖 AnimalWild…／世界地圖 WM 前綴）；
-- 風格/大小/顏色/物種與類別篩選、伺服器沙盒閘皆兩表面共用
local function drawAnimalDots(inner, wildOpt, liveOpt, vehOpt)
    -- 沙盒閘門逐玩家判定（管理員戰術檢視生效時 Policy 對這兩鍵回 true＝旁路）
    local pn = inner.playerNum or 0
    local allowAnimals = sandboxGate("AllowAnimalDots", true, pn) ~= false
    local wantWild = allowAnimals and getBoolOption(wildOpt, false)
    local wantLive = allowAnimals and getBoolOption(liveOpt, false)
    local wantVeh = getBoolOption(vehOpt, false)
        and sandboxGate("AllowVehicleDots", true, pn) ~= false
    if not (wantWild or wantLive or wantVeh) then return end -- 全關＝零成本
    local st = sampleAnimalDots(inner, wantWild, wantLive, wantVeh)
    if st.count == 0 then return end
    local styleItem = getComboIndex("AnimalIconStyle", 1) == 2
    -- 大小/透明度滑條每幀讀值（0.9.0 起動物/載具各自獨立；風格不再影響大小）
    local aSize = getSliderValue("AnimalIconSize", 16, 8, 48)
    local vSize = getSliderValue("VehicleIconSize", 16, 8, 48)
    local aAlpha = getSliderValue("AnimalIconAlpha", 100, 10, 100) / 100
    local vAlpha = getSliderValue("VehicleIconAlpha", 100, 10, 100) / 100
    -- 染色三下拉每幀讀值（同殭屍點顏色模式，存檔即生效）
    local wildC = adotsColor("AnimalWildColor", 2)
    local liveC = adotsColor("AnimalLivestockColor", 1)
    local vehC = adotsColor("VehicleIconColor", 4)
    local mapAPI = inner.mapAPI
    -- 仿射投影＋half 提出迴圈（perf 稽核 ICON-2/ICON-4）：投影同殭屍點（錨定
    -- 取樣時視野中心 st.acx、首點 fallback）；size 僅 aSize/vSize 兩種，
    -- math.floor（跨界）原每點一次改為迴圈前各一次
    local aHalf = math.floor(aSize / 2)
    local vHalf = math.floor(vSize / 2)
    local d1 = st.dots[1]
    local pax = st.acx or (d1.x - d1.x % 1)
    local pay = st.acy or (d1.y - d1.y % 1)
    local p0x, p0y, sxx, sxy, syx, syy = deriveAffine(mapAPI, pax, pay)
    for i = 1, st.count do
        local d = st.dots[i]
        local size = d.veh and vSize or aSize
        local half = d.veh and vHalf or aHalf -- 圖標中心對齊目標位置
        local ddx, ddy = d.x - pax, d.y - pay
        local ux = p0x + ddx * sxx + ddy * syx - half
        local uy = p0y + ddx * sxy + ddy * syy - half
        -- 手動裁切同殭屍點位（Lua 繪製不吃元件裁切）；留 1px 邊給影子/描邊
        if ux >= 1 and uy >= 1 and ux + size <= inner.width - 1 and uy + size <= inner.height - 1 then
            if d.veh then -- 載具：恆用符號（無對應物品圖），顏色可自訂
                local tex = adotsTexture(ADOTS_VEH_SYM)
                if tex then
                    adotsDrawGlyph(inner, tex, ux, uy, size, vehC[1], vehC[2], vehC[3], vAlpha)
                end
            else
                local art = ADOTS_ART[d.group]
                local tex, asItem
                if styleItem and art then
                    tex = adotsTexture(art.item)
                    asItem = tex ~= nil
                end
                if not tex then
                    tex = adotsTexture(art and art.sym or ADOTS_FALLBACK_SYM)
                        or adotsTexture(ADOTS_FALLBACK_SYM)
                end
                if tex then
                    if asItem then
                        inner:drawRect(ux - 1, uy - 1, size + 2, size + 2, 0.75 * aAlpha, 0, 0, 0)
                        inner:drawTextureScaled(tex, ux, uy, size, size, aAlpha, 1, 1, 1)
                        if d.wild then -- 角標＝野生（彩圖不可染色，用角標區分；色跟野生下拉）
                            inner:drawRect(ux + size - 3, uy - 1, 4, 4, aAlpha,
                                wildC[1], wildC[2], wildC[3])
                        end
                    else
                        local c = d.wild and wildC or liveC
                        adotsDrawGlyph(inner, tex, ux, uy, size, c[1], c[2], c[3], aAlpha)
                    end
                end
            end
        end
    end
end

-- 主檔 prerender wrap 經 Core 動態呼叫（同 Core.drawNavRoute 慣例）
Core.drawZombieDotsOn = drawZombieDotsOn
Core.drawAnimalDots = drawAnimalDots
