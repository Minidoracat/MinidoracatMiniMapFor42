-- MinidoracatMiniMap.lua
-- Minidoracat MiniMap for B42 — 世界地圖 ImagePyramid 疊加層（client 端，單機/多人皆同）
--
-- 架構（manifest 驅動集合包 + 第三方 addon 相容，詳見專案 README.md）：
--   (1) 本 MOD 的 media/minimap/ 集中放各地圖的 pyramid zip（檔名＝地圖原名，
--       即 pzmap Studio 預設輸出名），MAPS manifest 宣告「哪顆 zip 對應哪個地圖 MOD」；
--       基底圖永遠掛載，地圖 MOD 的圖僅該 MOD 啟用時掛載（沒裝該地圖，畫它的圖＝錯）。
--   (2) 相容路徑：第三方 MOD 在自己的 media/minimap/ 放約定同名 zip（LEGACY_CANONICAL）
--       即被自動掃描掛載，零 Lua——原「基底 + addon 同檔名匹配」設計原封保留。
--   引擎面：一個 Pyramid 樣式層只綁一個檔名、以「尾綴匹配」全部已掛載 zip
--   （WorldMapPyramidStyleLayer.java:48: endsWith(File.separator + fileName)），
--   故每個「檔名」建一層。多層並存是原生支援：原版即掛 forest.pyramid.zip
--   （WorldMap.java:145-148）並為其建獨立 pyramid 樣式層（ISMapDefinitions.lua:337-339）。
--   疊層順序：newPyramidLayer 把新層 append 到層列尾（WorldMapStyleV2.java:21-24），
--   繪製對層列「正序」迭代（WorldMapRenderer.java:920-923）——後建的層畫在上面，
--   故基底層先建（最底）、addon 層後建（最上）。每顆 zip 自帶 bounds 自動對位。
--   注意：同一層內的同名多 zip（多個第三方 addon）引擎是「反序」迭代
--   （WorldMapPyramidStyleLayer.java:46-51），先註冊者畫在上面。

local OWN_MOD_ID = "MinidoracatMiniMapFor42" -- 同 mod.info 的 id

-- 本 MOD 自帶圖檔 manifest：zip＝media/minimap/ 下檔名；mapMod 省略＝基底、永遠掛載，
-- 指定時＝該地圖 MOD 的 mod ID，啟用才掛載。支援新地圖：pzmap Studio 渲染出
-- <地圖名>.pyramid.zip（預設輸出名，免改名）丟進 media/minimap/，在此加一行即可。
-- bounds＝渲染時 pyramid.txt 的世界 square 座標（右/下為排他邊界，
-- cell*256 推得，來源 MinidoracatMapRendering/src/pyramid.rs:179-186）；
-- nameKey＝UI.json 翻譯鍵，缺譯退 mod ID。兩者供 MOD 地圖框線/名稱顯示用。
local MAPS = {
    { zip = "Muldraugh_KY.pyramid.zip" }, -- 基底全圖（B42 主世界）
    { zip = "Muldraugh_FireDept.pyramid.zip", mapMod = "beek_muldraugh_firedept",
        bounds = { 10496, 8960, 11008, 9472 }, nameKey = "UI_MinidoracatMiniMap_Map_MuldraughFireDept" },
    { zip = "Estate 39.pyramid.zip", mapMod = "Estate 39",
        bounds = { 8192, 9728, 8704, 10240 }, nameKey = "UI_MinidoracatMiniMap_Map_Estate39" },
    { zip = "Chinatown Expansion B42 version.pyramid.zip", mapMod = "Chinatown Expansion B42 version",
        bounds = { 10752, 8192, 11264, 9216 }, nameKey = "UI_MinidoracatMiniMap_Map_Chinatown" },
    -- 同 Workshop 的互斥變體（mod.info incompatible=本體）：地圖目錄完全相同，
    -- 以同 zip/bounds 雙條目當 ID alias——掛載（絕對路徑去重）與建層（indexOfLayer）
    -- 自帶防重，即使兩 ID 同時啟用也安全
    { zip = "Chinatown Expansion B42 version.pyramid.zip", mapMod = "Chinatown Expansion B42 version (Less Traffic Jam)",
        bounds = { 10752, 8192, 11264, 9216 }, nameKey = "UI_MinidoracatMiniMap_Map_Chinatown" },
}

-- MOD 地圖框線繪製資料（collectPyramids 於地圖初始化時重建；drawMapBounds 每幀讀）
local mapOverlays = {}

-- 第三方 addon 相容約定檔名（零 Lua）：地圖 MOD 自附 minimap 支援時使用
local LEGACY_CANONICAL = "minidoracat_minimap.pyramid.zip"

local function log(msg)
    print("[MinidoracatMiniMap] " .. tostring(msg))
end

-- 回傳 <modRoot>/media/minimap/<zip> 的存在路徑；找不到回 nil。
-- 必須用平台分隔符組路徑：Pyramid 樣式層以 endsWith(File.separator .. fileName)
-- 匹配 zip，Windows 上用 "/" 串檔名會導致圖層永遠匹配不到。
-- B42 的 media 一律在版本目錄（42/）或 common/ 之下，不在 MOD 根目錄
-- （ChooseGameInfo.Mod 建構子；getVersionDir/getCommonDir 皆回傳絕對路徑）。
-- 版本目錄優先（與遊戲的 version-覆蓋-common 語意一致），每個 MOD 只取一顆。
local function findZip(modInfo, sep, zip)
    for _, root in ipairs({ modInfo:getVersionDir(), modInfo:getCommonDir() }) do
        if root then
            local path = root .. sep .. "media" .. sep .. "minimap" .. sep .. zip
            if fileExists(path) then
                return path
            end
        end
    end
    return nil
end

-- 回傳待掛載清單 { { path=絕對路徑, zip=檔名 }, ... }，順序＝MAPS 再 legacy addon
-- （applyMiniMapPyramids 依序掛載/建層，addon 層後建、畫在基底之上）
local function collectPyramids()
    local list = {}
    local sep = getFileSeparator()
    local mods = getActivatedMods()
    local active = {}
    for i = 1, mods:size() do
        active[mods:get(i - 1)] = true
    end

    -- 重建框線資料（世界地圖/小地圖各 init 一次呼叫本函式，冪等）：
    -- 有 bounds 且對應地圖 MOD 啟用者才畫框——框線不依賴 zip 是否渲染
    for i = #mapOverlays, 1, -1 do mapOverlays[i] = nil end
    for _, entry in ipairs(MAPS) do
        if entry.bounds and entry.mapMod and active[entry.mapMod] then
            table.insert(mapOverlays, entry)
        end
    end

    -- (1) 本 MOD manifest：基底 + 已啟用地圖 MOD 的圖檔。缺檔一律有 log——
    -- zip 是 gitignored 產物，「漏渲染／漏打包」是最可能的事故，不能靜默
    local own = getModInfoByID(OWN_MOD_ID)
    if own then
        for _, entry in ipairs(MAPS) do
            if not entry.mapMod or active[entry.mapMod] then
                local path = findZip(own, sep, entry.zip)
                if path then
                    table.insert(list, { path = path, zip = entry.zip })
                elseif not entry.mapMod then
                    log("基底圖檔缺失: " .. entry.zip .. "（尚未渲染？應位於 42/media/minimap/，見 scripts/build_pyramids.ps1）")
                else
                    log("地圖 MOD " .. entry.mapMod .. " 已啟用，但集合包缺 " .. entry.zip .. "（漏渲染或漏打包？）")
                end
            end
        end
    else
        log("getModInfoByID(\"" .. OWN_MOD_ID .. "\") 回 nil——OWN_MOD_ID 與 mod.info 的 id 不符？manifest 圖層全數停用")
    end

    -- (2) 相容路徑：掃描其他啟用 MOD 的約定同名 zip（第三方 addon，零 Lua）。
    -- 排除本 MOD 自己：本 MOD 走 manifest；開發機殘留的舊約定檔名 zip 不該被雙掛
    for i = 1, mods:size() do
        local modID = mods:get(i - 1)
        if modID ~= OWN_MOD_ID then
            local modInfo = getModInfoByID(modID)
            if modInfo then
                local path = findZip(modInfo, sep, LEGACY_CANONICAL)
                if path then
                    table.insert(list, { path = path, zip = LEGACY_CANONICAL })
                end
            end
        end
    end
    return list
end

local function applyMiniMapPyramids(mapUI)
    local mapAPI = mapUI.mapAPI
    local styleAPI = mapAPI:getStyleAPI()

    local entries = collectPyramids()
    if #entries == 0 then
        log("未找到任何 pyramid zip，不加圖層")
        return
    end

    -- 掛載 zip（Java 側 WorldMap.addImagePyramid 自帶去重，重開地圖重複呼叫安全）
    for _, e in ipairs(entries) do
        mapAPI:addImagePyramid(e.path)
        log("已掛載 pyramid: " .. e.path)
    end

    -- 樣式層：疊在原版樣式之上，不清空原版（刻意不學 showTerrainImage 的 styleAPI:clear()）。
    -- 每個「檔名」一層（引擎一層只綁一個檔名）；防重複註冊：圖層已存在就不重加
    for _, e in ipairs(entries) do
        local layerId = "minidoracat_" .. (e.zip:gsub("%.pyramid%.zip$", ""))
        if styleAPI:indexOfLayer(layerId) == -1 then
            local layer = styleAPI:newPyramidLayer(layerId)
            layer:setPyramidFileName(e.zip)
            layer:addFill(0.0, 255.0, 255.0, 255.0, 255.0)
        end
    end

    mapAPI:setBoolean("ImagePyramid", true)
    log("圖層就緒（" .. #entries .. " 個 pyramid zip）")
end

--------------------------------------------------------------------------------
-- MOD 選項（PZAPI.ModOptions，B42 官方 API）
-- 主選單「選項 → 模組」頁；值由引擎存讀 ModOptions.ini
-- （MainOptions.lua:2823 load、3793 save，皆引擎自動，本 MOD 不碰檔案）。
--------------------------------------------------------------------------------

-- 尺寸倍率表：索引對應下拉選單項目順序（小=原版、中 1.5x、大 2x、特大 2.5x）
local SIZE_SCALES = { 1.0, 1.5, 2.0, 2.5 }
local DEFAULT_SIZE_INDEX = 2 -- 預設「中」

local modOptions -- PZAPI Options 實例；PZAPI 不存在（版本過舊）時為 nil，一切走原版行為

-- 讀目前尺寸索引（防呆：選項不存在或存檔值超界時回預設）
local function getSizeIndex()
    if not modOptions then return DEFAULT_SIZE_INDEX end
    local opt = modOptions:getOption("MapSize")
    local idx = opt and opt:getValue()
    return SIZE_SCALES[idx] and idx or DEFAULT_SIZE_INDEX
end

local function getBoolOption(id, default)
    if not modOptions then return default end
    local opt = modOptions:getOption(id)
    if opt == nil then return default end
    return opt:getValue()
end

-- 沙盒管理閘門（media/sandbox-options.txt 定義）：MP 由伺服器沙盒值決定、
-- 客戶端每幀讀值——管理員沙盒面板改動同步到客戶端後即時生效；
-- 單機或舊存檔缺表/缺鍵時一律回 default（＝允許）
local function sandboxGate(name, default)
    local sb = SandboxVars and SandboxVars.MinidoracatMiniMap
    local v = sb and sb[name]
    if v == nil then return default end
    return v
end

-- combobox 值＝選中項索引（同 AdornMode 用法）；超界或無選項回預設
local function getComboIndex(id, default)
    if not modOptions then return default end
    local opt = modOptions:getOption(id)
    local v = opt and opt:getValue()
    if type(v) ~= "number" then return default end
    return v
end

-- 按鈕列（titleBar＋bottomPanel adornments）是否「永遠顯示」（combobox 索引 1=滑鼠
-- 懸停時（原版）、2=永遠顯示）。預設永遠顯示；無 PZAPI（選項不存在）時維持原版行為。
local function isAdornAlways()
    if not modOptions then return false end
    local opt = modOptions:getOption("AdornMode")
    local v = opt and opt:getValue()
    if v ~= 1 and v ~= 2 then return true end -- 存檔值超界：回預設「永遠顯示」
    return v == 2
end

-- 把圖層開關套到指定小地圖 mapAPI（引擎選項名出自 WorldMapRenderer.java）
local function applyToggleOptions(mapAPI)
    mapAPI:setBoolean("Players", getBoolOption("Players", true))
    if isClient() then
        -- 隊友圖標與名字一起控（僅多人有效；單機照原版不動這兩個選項）
        local showRemote = getBoolOption("RemotePlayers", true)
        mapAPI:setBoolean("RemotePlayers", showRemote)
        mapAPI:setBoolean("PlayerNames", showRemote)
    end
    mapAPI:setBoolean("ZombieIntensity", getBoolOption("ZombieIntensity", false))
    -- 預設 true 跟隨引擎預設（WorldMapRenderer.java:122）——預設關會讓已開「符號」
    -- 的玩家裝 MOD 後地名消失。實際顯示還需齒輪面板的「符號(Symbols)」開啟
    -- （符號繪製整體被 Symbols 閘住，WorldMapRenderer.java:2151）。
    local placeNames = getBoolOption("PlaceNames", true)
    mapAPI:setBoolean("PlaceNames", placeNames)
    -- 地名開啟時連帶強制開 Symbols：原版會把 Symbols 關閉狀態存進 WorldMapSettings
    -- 跨場持久（ISMiniMap.lua:605-633 saveSettings/restoreSettings），不耦合就會出現
    -- 「開了地名卻永遠沒地名」死狀態；反向（地名關）不動 Symbols
    if placeNames then mapAPI:setBoolean("Symbols", true) end
    -- 實驗性文字註記：關閉 MiniMapSymbols 模式讓文字符號可畫（地名仍需
    -- PlaceNames＋Symbols 開啟）；代價是符號不再夾限縮放、玩家自畫標記
    -- 以完整尺寸顯示（WorldMapBaseSymbol.java:190/201），近 zoom 下可能偏大。
    -- 本函式只套用在角落小地圖的 mapAPI，不影響世界地圖。
    mapAPI:setBoolean("MiniMapSymbols", not getBoolOption("TextAnnotations", false))
    -- 街名顯示（資料已於 InitPlayer wrapper 補載；此值只控畫不畫，
    -- StreetRenderData.java:45 為唯一閘門，故存檔即生效）
    mapAPI:setBoolean("ShowStreetNames", getBoolOption("StreetNames", true))
end

-- 外框底色不透明度：縮放 outer／bottomPanel／titleBar 的 backgroundColor.a
-- （原版值首次套用時快照在 _minidoracatBgA，切回「原版」可還原）。
-- 地圖本體是 GPU 直繪（UIElement 無整體 alpha API），只能調整外框視覺重量。
local CHROME_FACTORS = { 1.0, 0.5, 0.15 }
local function applyChromeOpacity(mm)
    local f = CHROME_FACTORS[getComboIndex("Opacity", 1)] or 1.0
    -- titleBar 不在此列：它的背景是 prerender 直繪材質、不吃 backgroundColor
    -- （ISMiniMap.lua:354-357），由下方 prerender wrap 以因子重畫
    local parts = { mm, mm.bottomPanel }
    for i = 1, #parts do
        local el = parts[i]
        if el and el.backgroundColor then
            el._minidoracatBgA = el._minidoracatBgA or el.backgroundColor.a
            el.backgroundColor.a = el._minidoracatBgA * f
        end
    end
end

-- 標題列透明度：原版 prerender 是單行 alpha=1 材質直繪（ISMiniMap.lua:354-357，
-- drawTextureScaled(titlebarbkg,1,1,w-2,th-2,1,1,1,1)），已畫上去的無法事後調淡，
-- 只能在因子 <1 時以相同引數改 alpha 重畫（忠實複製該行，引數順序 a,r,g,b）
if ISMiniMapTitleBar and ISMiniMapTitleBar.prerender then
    local originalTitleBarPrerender = ISMiniMapTitleBar.prerender
    function ISMiniMapTitleBar:prerender()
        local f = CHROME_FACTORS[getComboIndex("Opacity", 1)] or 1.0
        if f >= 1.0 then return originalTitleBarPrerender(self) end
        local th = self:titleBarHeight()
        self:drawTextureScaled(self.titlebarbkg, 1, 1, self:getWidth() - 2, th - 2, f, 1, 1, 1)
    end
end

--------------------------------------------------------------------------------
-- 邊緣拖曳縮放：常數與自訂尺寸解析（滑鼠互動 hook 在檔案下方「邊緣拖曳縮放」一節；
-- 這裡先定義是因為 modOptions:apply() 與 InitPlayer hook 都要用）
--------------------------------------------------------------------------------

local RESIZE_EDGE = 8         -- 邊緣熱區厚度（px）
local RESIZE_MIN = 180        -- 基準尺寸下限（px）
local RESIZE_MAX_RATIO = 0.85 -- 尺寸上限 = 玩家螢幕短邊 85%（實測 70% 太緊）

-- 前置宣告（定義在下方「邊緣拖曳縮放」節）：InitPlayer hook 要對 bottomPanel
-- 實例補掛縮放事件——它是裸 ISPanel（ISMiniMap.lua:419），hook class 會波及
-- 全遊戲的 ISPanel，只能每次重建時掛實例。
local installResizeHooks
local cancelResize
-- 導航目標表前置宣告（InitPlayer wrapper 要載回 modData；本體與註解見導航一節）
local navTargets = {}
-- 按鈕列擴充/設定視窗前置宣告（InitPlayer 與 onButton4 覆寫要用；本體見設定視窗一節）
local installMinidoracatButtons
local toggleSettingsWindow

-- 尺寸上限（getPlayerScreenWidth/Height 用例 ISMiniMap.lua:701-702）
local function resizeMax(playerNum)
    return math.floor(math.min(getPlayerScreenWidth(playerNum), getPlayerScreenHeight(playerNum)) * RESIZE_MAX_RATIO)
end

-- 讀自訂尺寸欄位原始字串（apply()/InitPlayer 判斷欄位是否變動用）
local function getCustomSizeRaw()
    if not modOptions then return "" end
    local opt = modOptions:getOption("CustomSize")
    return opt and tostring(opt:getValue() or "") or ""
end

-- 解析自訂尺寸「寬x高」（邊緣拖曳縮放自動寫入；清空欄位＝回到下拉尺寸）。
-- 回傳夾限後的 w, h；沒設或格式不對回 nil。
-- Kahlua 有 string.match（用例 ISChat.lua:563）。
local function getCustomSize(playerNum)
    local v = getCustomSizeRaw()
    local w, h = string.match(v, "^%s*(%d+)%s*[xX]%s*(%d+)%s*$")
    if not w then return nil end
    local maxWH = resizeMax(playerNum)
    w = math.max(RESIZE_MIN, math.min(maxWH, tonumber(w)))
    h = math.max(RESIZE_MIN, math.min(maxWH, tonumber(h)))
    return w, h
end

if PZAPI and PZAPI.ModOptions then
    modOptions = PZAPI.ModOptions:create("MinidoracatMiniMap", "UI_MinidoracatMiniMap_Options")

    -- 注意：combobox 的 tooltip 在 MainOptions.lua（2942-2965）沒有被顯示，故不設
    local sizeCombo = modOptions:addComboBox("MapSize", "UI_MinidoracatMiniMap_Size")
    sizeCombo:addItem("UI_MinidoracatMiniMap_Size_Small", false)
    sizeCombo:addItem("UI_MinidoracatMiniMap_Size_Medium", true) -- 預設「中」
    sizeCombo:addItem("UI_MinidoracatMiniMap_Size_Large", false)
    sizeCombo:addItem("UI_MinidoracatMiniMap_Size_Huge", false)

    -- 按鈕列顯示模式（問題 A）：原版 hover 展開/收合會改變外框高度、把地圖核心
    -- 往上推（詳見下方 setAdornmentsVisible wrap 一節）。不做「永遠隱藏」——
    -- 齒輪與縮放按鈕會不可達。
    local adornCombo = modOptions:addComboBox("AdornMode", "UI_MinidoracatMiniMap_AdornMode")
    adornCombo:addItem("UI_MinidoracatMiniMap_AdornMode_Hover", false)
    adornCombo:addItem("UI_MinidoracatMiniMap_AdornMode_Always", true) -- 預設「永遠顯示」

    modOptions:addTickBox("Players", "UI_MinidoracatMiniMap_Players", true,
        "UI_MinidoracatMiniMap_Players_tooltip")
    modOptions:addTickBox("RemotePlayers", "UI_MinidoracatMiniMap_RemotePlayers", true,
        "UI_MinidoracatMiniMap_RemotePlayers_tooltip")
    -- 安全屋範圍（本 MOD 純 Lua 自繪，見下方 drawSafehouses）：繪製端每幀讀值即時生效
    modOptions:addTickBox("Safehouses", "UI_MinidoracatMiniMap_Safehouses", true,
        "UI_MinidoracatMiniMap_Safehouses_tooltip")
    -- MOD 地圖框線＋名稱（純 Lua 自繪，見下方 drawMapBounds）：同上即時生效
    modOptions:addTickBox("MapBounds", "UI_MinidoracatMiniMap_MapBounds", true,
        "UI_MinidoracatMiniMap_MapBounds_tooltip")
    modOptions:addTickBox("ZombieIntensity", "UI_MinidoracatMiniMap_ZombieIntensity", false,
        "UI_MinidoracatMiniMap_ZombieIntensity_tooltip")
    modOptions:addTickBox("PlaceNames", "UI_MinidoracatMiniMap_PlaceNames", true,
        "UI_MinidoracatMiniMap_PlaceNames_tooltip")
    -- 街名：原版只有世界地圖載入街道資料（ISWorldMap.lua:1450→
    -- MapUtils.initDefaultStreetData），小地圖從未載入 streets.xml，
    -- ShowStreetNames 預設開也無字可畫——本 MOD 於小地圖建立時補載資料（見
    -- InitPlayer wrapper），此開關控制顯示（引擎選項 ShowStreetNames）。
    modOptions:addTickBox("StreetNames", "UI_MinidoracatMiniMap_StreetNames", true,
        "UI_MinidoracatMiniMap_StreetNames_tooltip")
    -- 實驗性：小地圖完整符號模式。原版小地圖固定 MiniMapSymbols=true
    -- （ISMiniMap.lua:733），該模式下文字符號一律不畫（WorldMapTextSymbol.java:168）
    -- ——「顯示地名」在角落小地圖因此看不到字，只有世界地圖（M）有效。
    modOptions:addTickBox("TextAnnotations", "UI_MinidoracatMiniMap_TextAnnotations", false,
        "UI_MinidoracatMiniMap_TextAnnotations_tooltip")
    -- 點擊小地圖開啟世界地圖（原版行為＝onMouseUp 無拖曳即 ToggleWorldMap，
    -- ISMiniMap.lua:239-245）。預設關：把點擊留給未來的小地圖互動；
    -- M 鍵與按鈕列的 M 鈕不受影響。
    modOptions:addTickBox("ClickOpenWorldMap", "UI_MinidoracatMiniMap_ClickOpenWorldMap", false,
        "UI_MinidoracatMiniMap_ClickOpenWorldMap_tooltip")
    -- 拖曳自由查看：拖動後停留該處、點擊回到玩家（原版是放開就回中，
    -- ISMiniMap.lua:214-225 prerenderHack 每幀回中）
    modOptions:addTickBox("FreeLook", "UI_MinidoracatMiniMap_FreeLook", true,
        "UI_MinidoracatMiniMap_FreeLook_tooltip")
    -- 精準殭屍點位（預設關）；齒輪面板另以自訂 ISTickBox 注入同步開關
    -- （它原生只列引擎選項物件，這是純 Lua 自繪——見下方「齒輪面板」一節）
    modOptions:addTickBox("ZombieDots", "UI_MinidoracatMiniMap_ZombieDots", false,
        "UI_MinidoracatMiniMap_ZombieDots_tooltip")
    -- 殭屍點樣式：顏色與大小（繪製端每幀讀值，存檔即生效，無需重建）
    local zColorCombo = modOptions:addComboBox("ZombieDotColor", "UI_MinidoracatMiniMap_ZombieDotColor")
    zColorCombo:addItem("UI_MinidoracatMiniMap_ZDotColor_Orange", true) -- 預設橘
    zColorCombo:addItem("UI_MinidoracatMiniMap_ZDotColor_Yellow", false)
    zColorCombo:addItem("UI_MinidoracatMiniMap_ZDotColor_Purple", false)
    zColorCombo:addItem("UI_MinidoracatMiniMap_ZDotColor_White", false)
    zColorCombo:addItem("UI_MinidoracatMiniMap_ZDotColor_Red", false)
    local zSizeCombo = modOptions:addComboBox("ZombieDotSize", "UI_MinidoracatMiniMap_ZombieDotSize")
    zSizeCombo:addItem("UI_MinidoracatMiniMap_ZDotSize_Small", false)
    zSizeCombo:addItem("UI_MinidoracatMiniMap_ZDotSize_Medium", true) -- 預設中（3px）
    zSizeCombo:addItem("UI_MinidoracatMiniMap_ZDotSize_Large", false)
    -- 殭屍點上限（可視範圍內同時顯示的最大數量；取樣端每輪讀值即時生效）
    local zMaxCombo = modOptions:addComboBox("ZombieDotMax", "UI_MinidoracatMiniMap_ZombieDotMax")
    zMaxCombo:addItem("UI_MinidoracatMiniMap_ZDotMax_100", false)
    zMaxCombo:addItem("UI_MinidoracatMiniMap_ZDotMax_200", true) -- 預設 200
    zMaxCombo:addItem("UI_MinidoracatMiniMap_ZDotMax_400", false)
    zMaxCombo:addItem("UI_MinidoracatMiniMap_ZDotMax_800", false)
    -- 外框底色不透明度：只影響外框/按鈕列的黑底與其上的視覺重量；
    -- 地圖本體是 GPU 直繪（pyramid/圖磚不透明），引擎無整體 alpha 可調
    local opacityCombo = modOptions:addComboBox("Opacity", "UI_MinidoracatMiniMap_Opacity")
    opacityCombo:addItem("UI_MinidoracatMiniMap_Opacity_Full", true) -- 預設原版
    opacityCombo:addItem("UI_MinidoracatMiniMap_Opacity_Half", false)
    opacityCombo:addItem("UI_MinidoracatMiniMap_Opacity_Faint", false)
    -- 鎖定位置：擋標題列拖曳與邊緣縮放（hitResizeEdge 與 titleBar wrap 各自讀值）
    modOptions:addTickBox("LockPosition", "UI_MinidoracatMiniMap_LockPosition", false,
        "UI_MinidoracatMiniMap_LockPosition_tooltip")
    -- 自訂尺寸（textentry，PZAPI/ModOptions.lua:40）：拖曳小地圖邊緣縮放時自動寫入。
    -- 不存 WorldMapSettings：它非泛用 key-value——setDouble 只認建構時註冊的
    -- ConfigOption，未知鍵靜默 no-op（WorldMapSettings.java:73-77、32-42），
    -- 故改用 ModOptions；做成可見欄位讓玩家能手動清空還原。
    modOptions:addTextEntry("CustomSize", "UI_MinidoracatMiniMap_CustomSize", "",
        "UI_MinidoracatMiniMap_CustomSize_tooltip")

    -- 按「接受/套用」時由 MainOptions:apply 呼叫（3789）。該函式先跑 gameOptions:apply()
    -- （3787）把 UI 值寫回 option，所以此處 getValue() 已是新值。
    -- 無小地圖（主選單、沙盒未開 AllowMiniMap、尚未開圖）時只存值不動作。
    function modOptions:apply()
        if not getSpecificPlayer(0) then return end
        local mm = getPlayerMiniMap(0)
        if not mm then return end
        -- ponytail: 只處理 player 0，分割畫面其餘玩家沿用原版（原版 saveSettings 也只存 player 0）
        if mm._minidoracatSizeIndex ~= getSizeIndex() then
            -- 下拉改動＝快速重置：清掉自訂尺寸，以下拉倍率重建
            -- （之後引擎照常存 ModOptions.ini，MainOptions.lua:3793）
            local customOpt = self:getOption("CustomSize")
            if customOpt and tostring(customOpt:getValue() or "") ~= "" then
                customOpt:setValue("")
            end
            ISMiniMap.Recreate(0)
        elseif (mm._minidoracatCustomSize or "") ~= getCustomSizeRaw() then
            ISMiniMap.Recreate(0) -- 自訂尺寸欄位改動（含手動清空還原）：重建套用
        elseif mm.inner and mm.inner.mapAPI then
            applyToggleOptions(mm.inner.mapAPI) -- 純開關直接寫 mapAPI，即時生效
            applyChromeOpacity(mm) -- 外框不透明度亦即時生效
        end
        -- ZombieDots 免處理：繪製端每幀讀選項值，存檔即生效
    end
end

if not (ISWorldMap and ISWorldMap.initDataAndStyle) then
    log("找不到 ISWorldMap.initDataAndStyle，MOD 未啟用（遊戲版本不符？）")
    return
end

-- 掛在 ISWorldMap:initDataAndStyle 之後：該函式建立世界地圖資料與預設樣式
-- （內部呼叫 MapUtils.initDefaultStyleV3），是加自訂圖層的正確時機。
-- 不掛 MapUtils.initDefaultStyleV3 本身：LootMaps.Init.*（紙本地圖物品）也呼叫它，會被污染。
-- ponytail: 開圖狀態下切色盲選項或 debug TerrainImage 會重建樣式洗掉本圖層，重開地圖即恢復；
-- 需要更黏再改掛樣式重建點。
local originalInitDataAndStyle = ISWorldMap.initDataAndStyle
function ISWorldMap:initDataAndStyle()
    originalInitDataAndStyle(self)
    local ok, err = pcall(applyMiniMapPyramids, self)
    if not ok then
        log("初始化失敗: " .. tostring(err))
    end
end

-- 角落小地圖：ISMiniMap.InitPlayer 於玩家生成時建立（initDefaultStyleV1 後預設
-- ImagePyramid=false，applyMiniMapPyramids 會蓋回 true）。注意小地圖本身受沙盒
-- 選項 SandboxVars.Map.AllowMiniMap 控制（ISMiniMap.IsAllowed），沒開就不存在。
if ISMiniMap and ISMiniMap.InitPlayer then
    local originalInitPlayer = ISMiniMap.InitPlayer
    function ISMiniMap.InitPlayer(playerNum)
        -- 尺寸覆寫選型：InitPlayer 內部用區域變數算好 width/height 直接傳進
        -- ISMiniMapOuter:new，之後 createChildren/instantiate 都以 self.width 排版
        -- （inner、titleBar、bottomPanel、按鈕置中）。建好後再 setWidth 追不回這些
        -- 子元件版面，還得手動同步 javaObject，故採「呼叫期間暫時覆寫
        -- ISMiniMapOuter.new 放大寬高」——原版自己用新尺寸排版，零版面補丁。
        local sizeIndex = getSizeIndex()
        local scale = SIZE_SCALES[sizeIndex]
        -- 自訂尺寸（邊緣拖曳縮放寫入）存在時優先於下拉倍率
        local customW, customH = getCustomSize(playerNum)
        local minimap
        if (customW ~= nil or scale ~= 1.0) and ISMiniMapOuter then
            local originalNew = ISMiniMapOuter.new
            ISMiniMapOuter.new = function(self, x, y, width, height, pn)
                local w = customW or math.floor(width * scale + 0.5)
                local h = customH or math.floor(height * scale + 0.5)
                -- InitPlayer 以螢幕右下角定位（x = 右緣 - 10 - width），放大後
                -- 平移 x/y 保持右下角錨點不變（prerender 的 setPosition 也會再校正）
                return originalNew(self, x + width - w, y + height - h, w, h, pn)
            end
            local ok, result = pcall(originalInitPlayer, playerNum)
            ISMiniMapOuter.new = originalNew -- 無論成敗都還原，不留全域污染
            if not ok then error(result, 0) end
            minimap = result
        else
            minimap = originalInitPlayer(playerNum)
        end
        if minimap then
            minimap._minidoracatSizeIndex = sizeIndex -- 給 modOptions:apply() 判斷是否需重建
            minimap._minidoracatCustomSize = getCustomSizeRaw() -- 同上：自訂尺寸欄位變動判斷
            -- 「永遠顯示」模式：建好即展開按鈕列，之後高度恆定（prerender 的自動
            -- 收合被下方 setAdornmentsVisible wrap 擋掉），地圖核心永不位移
            if isAdornAlways() and minimap.setAdornmentsVisible then
                minimap:setAdornmentsVisible(true)
            end
            -- 底邊熱區：bottomPanel 會消化 mouse down（ISPanel onMouseDown 回
            -- isWantMouseEvents()，ISUIElement 預設 true），事件不會落回 outer——
            -- 對實例補掛同套縮放處理，底邊/下角的拖曳才有效。
            if installResizeHooks and minimap.bottomPanel then
                installResizeHooks(minimap.bottomPanel, function(el) return el.parent end)
            end
            if minimap.inner and minimap.inner.mapAPI then
                local ok, err = pcall(applyMiniMapPyramids, minimap.inner)
                if not ok then
                    log("小地圖初始化失敗: " .. tostring(err))
                end
                pcall(applyToggleOptions, minimap.inner.mapAPI)
                -- 街道資料補載：原版小地圖不載 streets.xml（只有世界地圖載，
                -- ISWorldMap.lua:1450），ShowStreetNames 開著也無字可畫。走同一
                -- 函式（ISMapDefinitions.lua:41-49，只用 mapUI.javaObject）——
                -- 翻譯 MOD wrap 它載入的中文街名（CatLangFor42 MapStreets_Flx）一併生效
                if MapUtils and MapUtils.initDefaultStreetData then
                    pcall(MapUtils.initDefaultStreetData, minimap.inner)
                end
            end
            pcall(applyChromeOpacity, minimap)
            -- 導航目標持久化載回（存於角色 modData，見下方導航一節）
            local pObj = getSpecificPlayer(playerNum)
            local md = pObj and pObj:getModData()
            if md and md.MinidoracatMiniMapTX and md.MinidoracatMiniMapTY then
                navTargets[playerNum] = { x = md.MinidoracatMiniMapTX, y = md.MinidoracatMiniMapTY }
            else
                navTargets[playerNum] = nil -- 新角色/無目標：清掉同槽位舊角色殘值
            end
            -- 按鈕列擴充（C＝回中、=＝圖層、齒輪＝設定視窗；見設定視窗一節）
            if installMinidoracatButtons then pcall(installMinidoracatButtons, minimap) end
        end
        return minimap
    end
end

-- 按鈕列顯示模式（問題 A）：原版 prerender 依滑鼠位置每幀自動展開/收合 adornments
-- （titleBar 上方＋bottomPanel 下方，ISMiniMap.lua:456-460），而 setAdornmentsVisible
-- 展開時上移 y、加高外框（ISMiniMap.lua:479-497），配合 setPosition 底部錨定
--（ISMiniMap.lua:557-561）＝滑鼠移上去地圖核心整個往上跳。
-- 「永遠顯示」（預設）把 visible 強制為 true：首幀展開一次後高度恆定、核心永不
-- 位移；已展開時傳 true 是 no-op（ISMiniMap.lua:481），無每幀重排成本。
-- 「滑鼠懸停時」＝原封不動走原版。
if ISMiniMapOuter and ISMiniMapOuter.setAdornmentsVisible then
    local originalSetAdornmentsVisible = ISMiniMapOuter.setAdornmentsVisible
    function ISMiniMapOuter:setAdornmentsVisible(visible)
        if isAdornAlways() then visible = true end
        originalSetAdornmentsVisible(self, visible)
    end
end

-- 齒輪面板（小地圖右下設定鈕）：在原版可見選項（Isometric/Symbols/RemoteSymbols）
-- 之後追加圖層開關。勾選文字沿用原版 IGUI_MapOption_<Name> 翻譯鍵
-- （原版缺 ZombieIntensity 三語與 PlaceNames 中文，由本 MOD 的 IG_UI.json 補）。
if ISMiniMapOptionsPanel and ISMiniMapOptionsPanel.getVisibleOptions then
    local originalGetVisibleOptions = ISMiniMapOptionsPanel.getVisibleOptions
    function ISMiniMapOptionsPanel:getVisibleOptions()
        local result = originalGetVisibleOptions(self)
        if self.showAllOptions then return result end -- debug/admin 模式已列全量，不重複加
        local names = { "Players" }
        if isClient() then -- 隊友圖標與名字僅多人顯示
            table.insert(names, "RemotePlayers")
            table.insert(names, "PlayerNames")
        end
        table.insert(names, "ZombieIntensity")
        table.insert(names, "PlaceNames")
        for _, name in ipairs(names) do
            for i = 1, self.map.mapAPI:getOptionCount() do
                local option = self.map.mapAPI:getOptionByIndex(i - 1)
                if option:getName() == name then
                    table.insert(result, option)
                    break
                end
            end
        end
        return result
    end
end

-- 齒輪面板勾「地名」時連帶開「符號」：同 applyToggleOptions 的閘門耦合，這裡補
-- 齒輪面板的即時路徑（原版 onTickBox 只寫單一選項值，ISMiniMap.lua:14-20）。
-- 只在勾選 PlaceNames 時觸發；我們注入的殭屍點位 tickbox 走自訂 handler 不經此處。
if ISMiniMapOptionsPanel and ISMiniMapOptionsPanel.onTickBox then
    local originalPanelOnTickBox = ISMiniMapOptionsPanel.onTickBox
    function ISMiniMapOptionsPanel:onTickBox(index, selected, option)
        originalPanelOnTickBox(self, index, selected, option)
        if selected and option and option.getName and option:getName() == "PlaceNames" then
            self.map.mapAPI:setBoolean("Symbols", true)
            self:synchUI() -- 讓「符號」勾選框立即反映（synchUI＝ISMiniMap.lua:128）
        end
    end
end

-- 齒輪面板追加本 MOD 開關（問題 C＋常用即時開關）：面板原生 createChildren 只列
-- 引擎選項物件（getVisibleOptions → ISTickBox/ISTextEntryBox，ISMiniMap.lua:45-78），
-- 這些是 ModOptions 選項——wrap createChildren 在原清單之後注入自訂 ISTickBox
-- （建法對照原版 ISMiniMap.lua:48-57），勾選直接寫回 ModOptions 並立即存檔/生效。
-- 樣式類（顏色/大小/透明度）刻意不進面板：屬「設定一次」偏好且需下拉元件，留選項頁。
-- 無 PZAPI（modOptions 為 nil，值無處持久化）時不注入。
if ISMiniMapOptionsPanel and ISMiniMapOptionsPanel.createChildren
    and ISMiniMapOptionsPanel.synchUI and ISTickBox then

    -- id＝ModOptions 選項名；default 需與選項預設一致；label 直接沿用選項頁 UI_ 鍵
    -- （getTextOrNull 依前綴查對應 domain，UI_ 鍵在 UI.json）；apply＝勾選後的即時動作
    -- （ZombieDots 繪製端與 LockPosition 事件端每幀/每次讀值，無需 apply）
    local GEAR_TICKS = {
        { id = "ZombieDots", label = "IGUI_MapOption_ZombieDots", default = false },
        { id = "StreetNames", label = "UI_MinidoracatMiniMap_StreetNames", default = true,
            apply = function(panel, selected)
                if panel.map and panel.map.mapAPI then
                    panel.map.mapAPI:setBoolean("ShowStreetNames", selected)
                end
            end },
        { id = "Safehouses", label = "UI_MinidoracatMiniMap_Safehouses", default = true },
        { id = "MapBounds", label = "UI_MinidoracatMiniMap_MapBounds", default = true },
        { id = "LockPosition", label = "UI_MinidoracatMiniMap_LockPosition", default = false },
    }

    -- 勾選變更 handler：ISTickBox 回呼簽名 (target, index, selected, args...)
    -- （ISTickBox.lua:175-176；原版同款且同以第 4 參傳資料，ISMiniMap.lua:14/48）
    function ISMiniMapOptionsPanel:onMinidoracatTick(index, selected, entry)
        if not modOptions or not entry then return end
        local opt = modOptions:getOption(entry.id)
        if not opt then return end
        opt:setValue(selected) -- option.setValue 會同步 MOD 選項頁的 element（ModOptions.lua:68-73）
        PZAPI.ModOptions:save() -- 立即落地 ModOptions.ini（PZAPI/ModOptions.lua:259）
        if entry.apply then entry.apply(self, selected) end
    end

    local originalPanelCreateChildren = ISMiniMapOptionsPanel.createChildren
    function ISMiniMapOptionsPanel:createChildren()
        originalPanelCreateChildren(self)
        if not modOptions then return end
        -- 原版收尾以「子元件最大 bottom＋resizeWidgetHeight」定面板高
        -- （ISMiniMap.lua:80-87），故內容底 = self.height - resizeWidgetHeight()；
        -- 注入點＝內容底再空 6px（同原版行距），面板逐列加高同額
        local entryHgt = getTextManager():getFontHeight(UIFont.Small) + 6 -- BUTTON_HGT（ISMiniMap.lua:7-9）
        local xPad = 10 + 1 -- UI_BORDER_SPACING + 1（ISMiniMap.lua:8/29）
        local y = self.height - self:resizeWidgetHeight() + 6
        -- 面板重建路徑（synchUI 全清子元件重跑 createChildren，ISMiniMap.lua:133-142）：
        -- 舊 tickbox 已被 removeChild，這裡蓋掉引用表＝不重複、不殘留
        self._minidoracatTicks = {}
        local maxRight = self.width
        for i = 1, #GEAR_TICKS do
            local entry = GEAR_TICKS[i]
            -- ISTickBox:new(x,y,w,h,name,target,method,arg)＝ISTickBox.lua:282；用法同 ISMiniMap.lua:48
            local tickBox = ISTickBox:new(xPad, y, self.width, entryHgt, "", self,
                self.onMinidoracatTick, entry)
            tickBox:initialise()
            tickBox:addOption(getTextOrNull(entry.label) or entry.id) -- addOption＝ISTickBox.lua:227
            tickBox:setSelected(1, getBoolOption(entry.id, entry.default)) -- setSelected＝ISTickBox.lua:51
            tickBox:setWidthToFit() -- ISTickBox.lua:266
            self:addChild(tickBox)
            self:insertNewLineOfButtons(tickBox) -- 手把導航登記（原版每列都登記，ISMiniMap.lua:57）
            self._minidoracatTicks[entry.id] = tickBox
            maxRight = math.max(maxRight, tickBox:getRight() + xPad)
            y = y + entryHgt + 6
            self:setHeight(self.height + entryHgt + 6)
        end
        self:setWidth(maxRight)
    end

    local originalPanelSynchUI = ISMiniMapOptionsPanel.synchUI
    function ISMiniMapOptionsPanel:synchUI()
        originalPanelSynchUI(self)
        -- 每次開面板同步勾選狀態（值可能在 MOD 選項頁被改過）
        if self._minidoracatTicks then
            for i = 1, #GEAR_TICKS do
                local entry = GEAR_TICKS[i]
                local box = self._minidoracatTicks[entry.id]
                if box then
                    box:setSelected(1, getBoolOption(entry.id, entry.default))
                end
            end
        end
    end
end

--------------------------------------------------------------------------------
-- 齒輪面板脫離 stencil 裁切（問題：小地圖縮小時面板被切頭）
-- 原版把面板掛成 inner（UIWorldMap）子元件、錨 inner 底往上長
-- （ISMiniMap.lua:583/593-594），而 UIWorldMap.render 以 stencil 把自身連同子元件
-- 裁在元件矩形內（UIWorldMap.java:162-163 setStencilRect、255-257 repaintStencilRect）
-- ——面板比小地圖高時頂部被切掉、選項點不到。
-- 修法：首次建立後把面板搬到 UIManager 頂層（ISCollapsableWindow 本來的用法；
-- 頂層元件一樣收得到點外面事件——UIManager.java:674 對非命中 UI 派發
-- onMouseButtonDownOutside → UIElement.java:1360-1362），每幀跟隨小地圖位置並夾在
-- 螢幕內；原版兩個走 self.parent.parent 鏈找 outer 的方法（onMouseDownOutside＝
-- ISMiniMap.lua:155、onJoypadDown＝:173）改由 self.map.parent 取 outer，
-- 於實例上覆寫（不動 class，別的用法不受影響）。
--------------------------------------------------------------------------------
if ISMiniMapOuter and ISMiniMapOuter.onToggleOptionsPanel then
    -- 夾進該玩家 viewport（分割畫面各佔半邊；取法同原版 outer 定位 ISMiniMap.lua:517-520）
    local function positionOptionsPanel(ui)
        local inner = ui.map
        local outer = inner.parent
        local pn = (outer and outer.playerNum) or 0
        local sx, sy = getPlayerScreenLeft(pn), getPlayerScreenTop(pn)
        local sw, sh = getPlayerScreenWidth(pn), getPlayerScreenHeight(pn)
        local x = inner:getAbsoluteX()
        local y = inner:getAbsoluteY() + inner:getHeight() - ui.height
        if x + ui.width > sx + sw then x = sx + sw - ui.width end
        if x < sx then x = sx end
        if y + ui.height > sy + sh then y = sy + sh - ui.height end
        if y < sy then y = sy end
        ui:setX(x)
        ui:setY(y)
    end

    -- 收面板＋歸還手把焦點：setVisible(false) 不會清 joypad focus
    -- （ISUIElement.lua:657-666 無相關處理），焦點卡在隱藏面板會鎖死手把導航——
    -- outer 還在就交還 outer，不在就清空（同 ToggleMiniMap 關閉做法 ISMiniMap.lua:755）
    local function hideOptionsPanel(ui)
        ui:setVisible(false)
        if ui.joyfocus then
            local outer = ui.map and ui.map.parent
            if outer and outer:isReallyVisible() then
                setJoypadFocus(ui.joyfocus.player, outer)
            else
                setJoypadFocus(ui.joyfocus.player, nil)
            end
        end
    end

    local originalToggleOptionsPanel = ISMiniMapOuter.onToggleOptionsPanel
    function ISMiniMapOuter:onToggleOptionsPanel()
        local wasVisible = self.optionsUI ~= nil and self.optionsUI:isVisible()
        originalToggleOptionsPanel(self)
        local ui = self.optionsUI
        if not ui then return end
        -- 一次性旗標判斷是否已搬家：不能拿 ui.parent 當判準——removeChild 只清
        -- children 表與 Java child，不清 Lua parent（ISUIElement.lua:1480-1491），
        -- 用 parent 判會每次重進本分支（prerender 疊套、重複 addToUIManager）
        if not ui._minidoracatTopLevel then
            ui._minidoracatTopLevel = true
            self.inner:removeChild(ui)
            ui.parent = nil -- removeChild 不清（同上），自行歸位免其他路徑誤判
            ui:addToUIManager()
            function ui:onMouseDownOutside(x, y)
                if self:isMouseOver() then return end
                local outer = self.map and self.map.parent
                if outer and outer.bottomPanel and outer.bottomPanel:isMouseOver() then return end
                hideOptionsPanel(self)
            end
            function ui:onJoypadDown(button, joypadData)
                if button == Joypad.BButton then
                    hideOptionsPanel(self)
                    return
                end
                ISCollapsableWindowJoypad.onJoypadDown(self, button, joypadData)
            end
            -- 頂層元件不再自動跟 parent 動：每幀跟隨小地圖（拖曳/縮放）。
            -- 兩種要自動收合的情境：小地圖整個關掉（ToggleMiniMap＝
            -- removeFromUIManager，ISMiniMap.lua:757→isReallyVisible false）；
            -- 手把開背包時原版只是把 outer 挪出畫面（setPosition 設 hideInventoryX，
            -- ISMiniMap.lua:499-514），inner 仍 isReallyVisible，須另查該旗標，
            -- 否則面板會被 viewport 夾回畫面內單獨懸空
            local originalUIPrerender = ui.prerender
            function ui:prerender()
                local inner = self.map
                local outer = inner and inner.parent
                if not (inner and inner:isReallyVisible()) or (outer and outer.hideInventoryX) then
                    hideOptionsPanel(self)
                    return
                end
                positionOptionsPanel(self)
                originalUIPrerender(self)
            end
        end
        if ui:isVisible() then
            positionOptionsPanel(ui)
            -- 拉回最上層：小地圖開關（ToggleMiniMap 對同實例 remove/add，
            -- ISMiniMap.lua:757/760）會讓 outer 在 UIManager 排到面板之後，
            -- 面板一開就被小地圖視窗蓋住＝「按齒輪沒反應」。
            -- bringToTop＝ISUIElement.lua:1548→UIElement.java:936（UIManager.pushToTop，
            -- parent nil 的頂層元件適用）；用例 ISCollapsableWindow.lua:212
            ui:bringToTop()
        elseif wasVisible then
            -- 齒輪鈕「再點一下關閉」走原版路徑（只 setVisible(false)，
            -- ISMiniMap.lua:588-591）——補跑 focus 歸還（對已隱藏面板冪等）
            hideOptionsPanel(ui)
        end
    end
end

-- 尺寸重建前收掉舊頂層面板：Recreate 對 outer 整個 removeFromUIManager 再新建
-- （ISMiniMap.lua:778-781），搬到頂層的面板不會跟著消失，須手動移除免殘留
if ISMiniMap and ISMiniMap.Recreate then
    local originalRecreate = ISMiniMap.Recreate
    function ISMiniMap.Recreate(playerNum)
        local mm = getPlayerMiniMap(playerNum)
        if mm and mm.optionsUI and mm.optionsUI._minidoracatTopLevel then
            local ui = mm.optionsUI
            ui:setVisible(false)
            -- 面板即將被移除且 outer 也要重建：焦點還在面板就直接清空，
            -- 不能留一個指向已移除 UI 的 joypad focus
            if ui.joyfocus then setJoypadFocus(ui.joyfocus.player, nil) end
            ui:removeFromUIManager()
            mm.optionsUI = nil
        end
        return originalRecreate(playerNum)
    end
end

--------------------------------------------------------------------------------
-- 詳細設定視窗＋按鈕列擴充（免跑 ESC 選項頁）：
--   齒輪鈕改開本視窗（原版齒輪＝開圖層面板，ISMiniMap.lua:578-580）；
--   圖層面板改掛新「=」鈕；「C」鈕＝回到玩家（清自由查看旗標）。
-- 視窗以 ISCollapsableWindow 頂層呈現（標題拖曳＋關閉鈕內建，
-- ISCollapsableWindow.lua:26-61），改值即寫回 ModOptions（同步 ESC 頁元件，
-- ModOptions.lua:68-73）並走既有 modOptions:apply()——尺寸重建/開關即時/
-- 透明度一條龍，不另寫套用邏輯。
--------------------------------------------------------------------------------
local SETTINGS_ROWS = {
    { kind = "combo", id = "MapSize", label = "UI_MinidoracatMiniMap_Size", default = 2,
        items = { "UI_MinidoracatMiniMap_Size_Small", "UI_MinidoracatMiniMap_Size_Medium",
            "UI_MinidoracatMiniMap_Size_Large", "UI_MinidoracatMiniMap_Size_Huge" } },
    { kind = "combo", id = "AdornMode", label = "UI_MinidoracatMiniMap_AdornMode", default = 2,
        items = { "UI_MinidoracatMiniMap_AdornMode_Hover", "UI_MinidoracatMiniMap_AdornMode_Always" } },
    { kind = "combo", id = "ZombieDotColor", label = "UI_MinidoracatMiniMap_ZombieDotColor", default = 1,
        items = { "UI_MinidoracatMiniMap_ZDotColor_Orange", "UI_MinidoracatMiniMap_ZDotColor_Yellow",
            "UI_MinidoracatMiniMap_ZDotColor_Purple", "UI_MinidoracatMiniMap_ZDotColor_White",
            "UI_MinidoracatMiniMap_ZDotColor_Red" } },
    { kind = "combo", id = "ZombieDotSize", label = "UI_MinidoracatMiniMap_ZombieDotSize", default = 2,
        items = { "UI_MinidoracatMiniMap_ZDotSize_Small", "UI_MinidoracatMiniMap_ZDotSize_Medium",
            "UI_MinidoracatMiniMap_ZDotSize_Large" } },
    { kind = "combo", id = "ZombieDotMax", label = "UI_MinidoracatMiniMap_ZombieDotMax", default = 2,
        items = { "UI_MinidoracatMiniMap_ZDotMax_100", "UI_MinidoracatMiniMap_ZDotMax_200",
            "UI_MinidoracatMiniMap_ZDotMax_400", "UI_MinidoracatMiniMap_ZDotMax_800" } },
    { kind = "combo", id = "Opacity", label = "UI_MinidoracatMiniMap_Opacity", default = 1,
        items = { "UI_MinidoracatMiniMap_Opacity_Full", "UI_MinidoracatMiniMap_Opacity_Half",
            "UI_MinidoracatMiniMap_Opacity_Faint" } },
    { kind = "tick", id = "FreeLook", label = "UI_MinidoracatMiniMap_FreeLook", default = true },
    { kind = "tick", id = "ClickOpenWorldMap", label = "UI_MinidoracatMiniMap_ClickOpenWorldMap", default = false },
    { kind = "tick", id = "TextAnnotations", label = "UI_MinidoracatMiniMap_TextAnnotations", default = false },
}
local settingsUI -- 單例；獨立頂層視窗，不隨小地圖 Recreate 消失（apply 自行重抓 mm）

local function settingsApply(entry, value)
    if not modOptions then return end
    local opt = modOptions:getOption(entry.id)
    if not opt then return end
    opt:setValue(value)
    -- 先 apply 再 save（同原版 MainOptions.lua:3787-3793 順序）：
    -- MapSize 的 apply() 會連帶清空 CustomSize，清除結果必須跟著落地
    if modOptions.apply then modOptions:apply() end
    PZAPI.ModOptions:save()
end

local function buildSettingsWindow()
    local fontH = getTextManager():getFontHeight(UIFont.Small)
    local rowH = fontH + 12
    local pad = 10
    local labelW = 150
    local widgetW = 160
    local win = ISCollapsableWindow:new(0, 0, pad + labelW + widgetW + pad, 100)
    win.resizable = false -- 同圖層面板做法（ISMiniMap.lua:187）
    win:setTitle(getText("UI_MinidoracatMiniMap_Options")) -- setTitle＝ISCollapsableWindow.lua:18-20
    win:initialise()
    win:addToUIManager()
    win:setVisible(false)
    win._minidoracatWidgets = {}
    local y = win:titleBarHeight() + 8
    for i = 1, #SETTINGS_ROWS do
        local entry = SETTINGS_ROWS[i]
        if entry.kind == "combo" then
            -- ISLabel 用法同圖層面板 double 列（ISMiniMap.lua:61-62）
            local label = ISLabel:new(pad, y + 3, fontH, getText(entry.label), 1, 1, 1, 1, UIFont.Small, true)
            win:addChild(label)
            -- ISComboBox:new(x,y,w,h,target,onChange,arg1,arg2)＝ISComboBox.lua:586；
            -- onChange(target, box, arg1)＝ISComboBox.lua:253
            local combo = ISComboBox:new(pad + labelW, y, widgetW, fontH + 6, win,
                function(target, box, e) settingsApply(e, box.selected) end, entry)
            combo:initialise()
            for j = 1, #entry.items do
                combo:addOption(getText(entry.items[j]))
            end
            combo.selected = getComboIndex(entry.id, entry.default)
            win:addChild(combo)
            win._minidoracatWidgets[entry.id] = combo
        else
            local tick = ISTickBox:new(pad, y, labelW + widgetW, fontH + 6, "", win,
                function(target, index, selected, e) settingsApply(e, selected) end, entry)
            tick:initialise()
            tick:addOption(getText(entry.label))
            tick:setSelected(1, getBoolOption(entry.id, entry.default))
            win:addChild(tick)
            win._minidoracatWidgets[entry.id] = tick
        end
        y = y + rowH
    end
    -- 恢復預設尺寸：清除拖曳縮放寫入的自訂長寬（CustomSize），回到尺寸下拉的
    -- 正方形（apply→save 順序同 settingsApply，清除結果須落地）
    local resetBtn = ISButton:new(pad, y + 2, labelW + widgetW, fontH + 8,
        getText("UI_MinidoracatMiniMap_ResetSize"), win, function()
            if not modOptions then return end
            local opt = modOptions:getOption("CustomSize")
            if not opt then return end
            opt:setValue("")
            if modOptions.apply then modOptions:apply() end
            PZAPI.ModOptions:save()
        end)
    resetBtn:initialise()
    resetBtn.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    resetBtn.tooltip = getText("UI_MinidoracatMiniMap_ResetSize_tooltip")
    win:addChild(resetBtn)
    y = y + rowH + 4
    win:setHeight(y + pad)
    return win
end

toggleSettingsWindow = function(outer)
    if not settingsUI then settingsUI = buildSettingsWindow() end
    if settingsUI:isVisible() then
        settingsUI:setVisible(false)
        return
    end
    for i = 1, #SETTINGS_ROWS do -- 開窗時同步現值（可能在 ESC 選項頁被改過）
        local entry = SETTINGS_ROWS[i]
        local wgt = settingsUI._minidoracatWidgets[entry.id]
        if wgt then
            if entry.kind == "combo" then
                wgt.selected = getComboIndex(entry.id, entry.default)
            else
                wgt:setSelected(1, getBoolOption(entry.id, entry.default))
            end
        end
    end
    -- 靠小地圖左側、夾進該玩家 viewport（取法同圖層面板定位）
    local pn = outer.playerNum or 0
    local sx, sy = getPlayerScreenLeft(pn), getPlayerScreenTop(pn)
    local sw, sh = getPlayerScreenWidth(pn), getPlayerScreenHeight(pn)
    local x = outer:getAbsoluteX() - settingsUI.width - 8
    local y = outer:getAbsoluteY()
    if x < sx then x = sx end
    if x + settingsUI.width > sx + sw then x = sx + sw - settingsUI.width end
    if y + settingsUI.height > sy + sh then y = sy + sh - settingsUI.height end
    if y < sy then y = sy end
    settingsUI:setX(x)
    settingsUI:setY(y)
    settingsUI:setVisible(true)
    settingsUI:bringToTop()
end

-- 按鈕列重排：7 顆（M - + C = ⚙ X）以動態間距塞進 inner 寬度
-- （原版置中排版只按 5 顆算，ISMiniMap.lua:417；最小寬 180 時縮間距到 2px 仍可容納）
local function relayoutBottomButtons(mm)
    local order = { mm.button1, mm.button2, mm.button3, mm._minidoracatCenterBtn,
        mm._minidoracatLayersBtn, mm.button4, mm.button6 }
    local btns = {}
    for i = 1, #order do
        if order[i] then btns[#btns + 1] = order[i] end
    end
    local n = #btns
    if n < 2 then return end
    local bw = btns[1].width
    local spacing = math.floor((mm.inner.width - n * bw) / (n - 1))
    if spacing > 10 then spacing = 10 end -- 上限＝UI_BORDER_SPACING（ISMiniMap.lua:8）
    if spacing < 2 then spacing = 2 end
    local x = math.floor((mm.inner.width - (n * bw + (n - 1) * spacing)) / 2)
    if x < 0 then x = 0 end
    for i = 1, n do
        btns[i]:setX(x)
        x = x + bw + spacing
    end
end

installMinidoracatButtons = function(mm)
    if not (mm and mm.bottomPanel and mm.button4 and ISButton) then return end
    local ref = mm.button4
    -- 「C」回到玩家：清自由查看旗標，下一幀 prerenderHack 恢復回中
    local cBtn = ISButton:new(0, ref.y, ref.width, ref.height, "C", mm, function(target)
        if target.inner then target.inner._minidoracatFreelook = nil end
    end)
    cBtn:initialise()
    cBtn.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 } -- 同原版按鈕（ISMiniMap.lua:424）
    cBtn.tooltip = getText("UI_MinidoracatMiniMap_BtnCenter") -- ISButton 內建 tooltip（ISButton.lua:317-321）
    mm.bottomPanel:addChild(cBtn)
    mm._minidoracatCenterBtn = cBtn
    -- 「=」圖層開關：原齒輪面板改掛這顆
    local lBtn = ISButton:new(0, ref.y, ref.width, ref.height, "=", mm, function(target)
        target:onToggleOptionsPanel()
    end)
    lBtn:initialise()
    lBtn.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    lBtn.tooltip = getText("UI_MinidoracatMiniMap_BtnLayers")
    mm.bottomPanel:addChild(lBtn)
    mm._minidoracatLayersBtn = lBtn
    mm.button4.tooltip = getText("UI_MinidoracatMiniMap_BtnSettings")
    -- 原版按鈕補 tooltip（M/-/+/X 原版無滑鼠提示；tooltip 欄位同上）
    if mm.button1 then mm.button1.tooltip = getText("UI_MinidoracatMiniMap_BtnWorldMap") end
    if mm.button2 then mm.button2.tooltip = getText("UI_MinidoracatMiniMap_BtnZoomOut") end
    if mm.button3 then mm.button3.tooltip = getText("UI_MinidoracatMiniMap_BtnZoomIn") end
    if mm.button6 then mm.button6.tooltip = getText("UI_MinidoracatMiniMap_BtnClose") end
    relayoutBottomButtons(mm)
    -- 7 顆按鈕的最小可容寬度回寫尺寸下限：UI 字型放大時 BUTTON_HGT 跟著變大，
    -- 固定 180 會塞不下（7 鈕＋6×2px 間距＋外框），動態墊高避免縮到溢出
    local minW = 7 * ref.width + 6 * 2 + (mm.borderSize or 2) * 2 + 4
    if minW > RESIZE_MIN then RESIZE_MIN = minW end
    -- ponytail: 新鈕未登記手把導航列（原版 insertNewLineOfButtons 於 createChildren
    -- 一次性登記，事後補列會亂序）；手把用戶仍可經圖層面板操作，需要時再補
end

-- 齒輪改開設定視窗；無 PZAPI（設定無處持久化）時維持原版行為（開圖層面板）
if ISMiniMapOuter and ISMiniMapOuter.onButton4 then
    local originalOnButton4 = ISMiniMapOuter.onButton4
    function ISMiniMapOuter:onButton4()
        if not modOptions then return originalOnButton4(self) end
        toggleSettingsWindow(self)
    end
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
-- 繪製掛 ISMiniMapInner:prerender：UIWorldMap.java:152 render 先畫地圖本體、
-- 行 317 才 super.render() → UIElement.java:1594 呼叫 Lua prerender，
-- 故點位畫在地圖之上、齒輪面板（inner 子元件，1604 子元件迴圈較晚畫）之下。
-- 世界地圖（M 鍵）刻意不畫：範圍太大、點位沒意義，只做角落小地圖。
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
local ZDOTS_SIZES = { 2, 3, 4 } -- 小／中（預設）／大（px，外圍另有 1px 黑描邊）
local ZDOTS_MAXES = { 100, 200, 400, 800 } -- 上限檔位（索引對應 ZombieDotMax combobox）
local ZDOTS_A = 1.0
local ZDOTS_EDGE_A = 0.8      -- 描邊透明度（黑）

-- ponytail: 掃描硬上限 4000——超過的清單尾端不掃（輪替起點掃描是升級路徑），
-- 實務上客戶端同步的殭屍數遠低於此，引擎也早在此之前就跑不動了
local ZDOTS_SCAN_MAX = 4000
-- 距離分層優先：視窗內殭屍數超過上限時，額度先給離玩家近的
-- （近圈→中圈→遠圈三桶，單次掃描免排序；桶各自封頂 maxDots，記憶體有界）
local ZDOTS_NEAR = 30 -- 近圈半徑（世界格）
local ZDOTS_MID = 80  -- 中圈半徑

-- 取樣狀態按 playerNum 分槽（分割畫面各玩家有各自的視窗/節流/點池，
-- 共用模組變數會讓第二位玩家沿用第一位的取樣結果）；槽位重用不產生每幀垃圾
local zdotsStates = {} -- [pn] = { dots, near, mid, far, count, nextMs }
local function zdotsStateFor(pn)
    local st = zdotsStates[pn]
    if not st then
        st = { dots = {}, near = {}, mid = {}, far = {}, count = 0, nextMs = 0 }
        zdotsStates[pn] = st
    end
    return st
end

local function sampleZombieDots(inner)
    local pn = inner.playerNum or 0
    local st = zdotsStateFor(pn)
    local now = getTimestampMs()
    if now < st.nextMs then return st end
    st.nextMs = now + ZDOTS_INTERVAL_MS
    st.count = 0
    local cell = getCell()
    local list = cell and cell:getZombieList()
    if not list then return st end
    -- 只收「小地圖可視範圍內」的殭屍再套 ZDOTS_MAX：getZombieList 的順序是
    -- 載入序而非距離序，早期版本取「清單前 N 隻」會被別處先生成的大群吃光
    -- 名額，玩家身邊的反而畫不出來（實測：管理員刷群後即重現）。
    -- 可視框＝視窗四角 uiToWorld（2 參數版用例 ISMiniMap.lua:234-235）的
    -- min/max 外接框（等軸測下視窗是世界座標裡的旋轉四邊形，外接框是超集，夠用）
    local mapAPI = inner.mapAPI
    local w, h = inner.width, inner.height
    local wx1, wy1 = mapAPI:uiToWorldX(0, 0), mapAPI:uiToWorldY(0, 0)
    local wx2, wy2 = mapAPI:uiToWorldX(w, 0), mapAPI:uiToWorldY(w, 0)
    local wx3, wy3 = mapAPI:uiToWorldX(w, h), mapAPI:uiToWorldY(w, h)
    local wx4, wy4 = mapAPI:uiToWorldX(0, h), mapAPI:uiToWorldY(0, h)
    local minX = math.min(wx1, wx2, wx3, wx4) - 2
    local maxX = math.max(wx1, wx2, wx3, wx4) + 2
    local minY = math.min(wy1, wy2, wy3, wy4) - 2
    local maxY = math.max(wy1, wy2, wy3, wy4) + 2
    -- 上限檔位每輪讀值（ZombieDotMax combobox），存檔即生效
    local maxDots = ZDOTS_MAXES[getComboIndex("ZombieDotMax", 2)] or ZDOTS_MAX
    -- 距離基準＝玩家位置（自由查看拖走視窗也以「離自己」為優先，符合直覺）；
    -- 無玩家（理論不會發生於 prerender）退回視窗中心
    local playerObj = getSpecificPlayer(pn)
    local px = playerObj and playerObj:getX() or ((minX + maxX) / 2)
    local py = playerObj and playerObj:getY() or ((minY + maxY) / 2)
    local near2 = ZDOTS_NEAR * ZDOTS_NEAR
    local mid2 = ZDOTS_MID * ZDOTS_MID
    -- pcall 防競態：getZombieList 是模擬端會增刪的活 ArrayList，size 與 get
    -- 之間殭屍被移除會丟 IndexOutOfBounds——失敗就放棄本輪取樣（300ms 後重試）
    local ok = pcall(function()
        local n = list:size()
        if n > ZDOTS_SCAN_MAX then n = ZDOTS_SCAN_MAX end
        local nearC, midC, farC = 0, 0, 0
        for i = 1, n do
            local z = list:get(i - 1)
            local zx, zy = z:getX(), z:getY()
            if zx >= minX and zx <= maxX and zy >= minY and zy <= maxY then
                local ddx, ddy = zx - px, zy - py
                local d2 = ddx * ddx + ddy * ddy
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
    if not ok then st.count = 0 end
    return st
end

--------------------------------------------------------------------------------
-- 安全屋範圍（Safehouses，預設開）：成員（含擁有者/受邀）＝綠框、他人＝紅框。
-- 四角經 worldToUIX/Y 投影後以 drawLine2 連線（ISUIElement.lua:1229）——
-- 等軸測（Isometric）投影下矩形成菱形，畫線才不失真。
-- 資料源：SafeHouse.getSafehouseList()（用例 ISSafehousesList.lua:61-62）、
-- 範圍 getX/getY/getX2/getY2（SafeHouse.java:596-632）、成員判定
-- playerAllowed(player)（SafeHouse.java:284，涵蓋 owner 與 players）。
-- 安全屋通常個位數，逐幀直畫免節流；線段超出視窗由 UIWorldMap stencil 裁切
-- （UIWorldMap.java:255-257，同齒輪面板被裁的機制，這裡反過來是助力），
-- 僅做粗略剔除省繪製呼叫。單機無安全屋＝清單空＝零成本。
--------------------------------------------------------------------------------
local SH_EDGE_A = 0.85

-- Liang-Barsky 線段裁切到 [0,w]×[0,h]：明確裁切、不依賴 stencil 行為
-- （UIWorldMap 的 stencil 在 Lua prerender 前已 clear/repaint，時序不可靠）。
-- clipEdge 是模組級閉包＋共用上值，每幀多次呼叫零配置（單執行緒 UI 安全）。
local clip_t0, clip_t1
local function clipEdge(p, q)
    if p == 0 then return q >= 0 end
    local t = q / p
    if p < 0 then
        if t > clip_t1 then return false end
        if t > clip_t0 then clip_t0 = t end
    else
        if t < clip_t0 then return false end
        if t < clip_t1 then clip_t1 = t end
    end
    return true
end
local function clipSegment(x1, y1, x2, y2, w, h)
    local dx, dy = x2 - x1, y2 - y1
    clip_t0, clip_t1 = 0, 1
    if not (clipEdge(-dx, x1) and clipEdge(dx, w - x1)
        and clipEdge(-dy, y1) and clipEdge(dy, h - y1)) then
        return nil
    end
    return x1 + clip_t0 * dx, y1 + clip_t0 * dy, x1 + clip_t1 * dx, y1 + clip_t1 * dy
end

-- 畫一條裁切後的邊：drawLine＝ISUIElement.lua:1235（收元件相對座標——
-- Java 端 DrawLine 自加 absolute offset，UIElement.java:489-492；nil 材質＝純色線，
-- 引擎自用例 AnimalPathfind.java:105）
local function drawClippedEdge(inner, x1, y1, x2, y2, r, g, b)
    local cx1, cy1, cx2, cy2 = clipSegment(x1, y1, x2, y2, inner.width, inner.height)
    if cx1 then
        inner:drawLine(nil, cx1, cy1, cx2, cy2, 1, SH_EDGE_A, r, g, b)
    end
end

local function drawSafehouses(inner)
    if not (SafeHouse and SafeHouse.getSafehouseList) then return end
    if not getBoolOption("Safehouses", true) then return end
    -- 沙盒顯示模式：1=關閉、2=僅自己的、3=全部（預設；缺表視為 3）
    local shMode = sandboxGate("SafehouseDisplay", 3)
    if shMode == 1 then return end
    local list = SafeHouse.getSafehouseList()
    if not list or list:size() == 0 then return end
    local playerObj = getSpecificPlayer(inner.playerNum or 0)
    local username = playerObj and playerObj:getUsername()
    local mapAPI = inner.mapAPI
    for i = 0, list:size() - 1 do
        local sh = list:get(i)
        local x1, y1 = sh:getX(), sh:getY()
        local x2, y2 = sh:getX2(), sh:getY2()
        -- 四角投影（worldToUIX/Y 同殭屍點位；等軸測下矩形成菱形故逐邊畫線）
        local ux1, uy1 = mapAPI:worldToUIX(x1, y1), mapAPI:worldToUIY(x1, y1)
        local ux2, uy2 = mapAPI:worldToUIX(x2, y1), mapAPI:worldToUIY(x2, y1)
        local ux3, uy3 = mapAPI:worldToUIX(x2, y2), mapAPI:worldToUIY(x2, y2)
        local ux4, uy4 = mapAPI:worldToUIX(x1, y2), mapAPI:worldToUIY(x1, y2)
        -- 成員判定走 String 版 playerAllowed（SafeHouse.java:290-292，只查
        -- owner＋players）——IsoPlayer 版（:284-287）含管理員 CanGoInsideSafehouses
        -- 後門，admin 測試會全判綠
        local mine = username ~= nil and sh:playerAllowed(username)
        if shMode ~= 2 or mine then -- 模式 2＝僅畫自己所屬的
            local r, g, b = 1.0, 0.25, 0.2            -- 他人＝紅
            if mine then r, g, b = 0.25, 0.95, 0.35 end -- 自己＝綠
            drawClippedEdge(inner, ux1, uy1, ux2, uy2, r, g, b)
            drawClippedEdge(inner, ux2, uy2, ux3, uy3, r, g, b)
            drawClippedEdge(inner, ux3, uy3, ux4, uy4, r, g, b)
            drawClippedEdge(inner, ux4, uy4, ux1, uy1, r, g, b)
        end
    end
end

--------------------------------------------------------------------------------
-- MOD 地圖範圍框線＋名稱（MapBounds，預設開）：對 manifest 裡「已啟用的地圖 MOD」
-- 依 bounds 畫青色框線，名稱畫在範圍中心（僅中心落在視窗內時畫——拉遠總覽定位用）。
-- 畫法同安全屋：四角 worldToUIX/Y 投影＋逐邊裁切畫線（等軸測下矩形成菱形）；
-- 名稱底墊同導航 label（drawRect 深底＋drawText，ISUIElement.lua:1191/1293）。
-- 只依賴 inner.mapAPI/.width/.height 與 ISUIElement 繪製方法——
-- 角落小地圖（ISMiniMapInner）與世界地圖（ISWorldMap，mapAPI 同為 getAPIv3，
-- ISWorldMap.lua:268）共用本函式。
--------------------------------------------------------------------------------
local MAPB_R, MAPB_G, MAPB_B = 0.35, 0.8, 1.0 -- 青藍：與安全屋綠/紅、玩家紅點區分

local function drawMapBounds(inner)
    if #mapOverlays == 0 then return end
    if not getBoolOption("MapBounds", true) then return end
    local mapAPI = inner.mapAPI
    for i = 1, #mapOverlays do
        local ov = mapOverlays[i]
        local x1, y1, x2, y2 = ov.bounds[1], ov.bounds[2], ov.bounds[3], ov.bounds[4]
        local ux1, uy1 = mapAPI:worldToUIX(x1, y1), mapAPI:worldToUIY(x1, y1)
        local ux2, uy2 = mapAPI:worldToUIX(x2, y1), mapAPI:worldToUIY(x2, y1)
        local ux3, uy3 = mapAPI:worldToUIX(x2, y2), mapAPI:worldToUIY(x2, y2)
        local ux4, uy4 = mapAPI:worldToUIX(x1, y2), mapAPI:worldToUIY(x1, y2)
        drawClippedEdge(inner, ux1, uy1, ux2, uy2, MAPB_R, MAPB_G, MAPB_B)
        drawClippedEdge(inner, ux2, uy2, ux3, uy3, MAPB_R, MAPB_G, MAPB_B)
        drawClippedEdge(inner, ux3, uy3, ux4, uy4, MAPB_R, MAPB_G, MAPB_B)
        drawClippedEdge(inner, ux4, uy4, ux1, uy1, MAPB_R, MAPB_G, MAPB_B)
        -- 名稱：缺譯退 mod ID（慣例同齒輪面板 getTextOrNull(label) or id）
        local name = getTextOrNull(ov.nameKey) or ov.mapMod
        if name then
            local tm = getTextManager()
            local tw = tm:MeasureStringX(UIFont.Small, name) -- 用例 ISFactionUI.lua:238
            local th = tm:getFontHeight(UIFont.Small) -- 字高隨 UI 字型倍率變動，不可硬編碼
            local cx = (ux1 + ux3) / 2 - tw / 2 -- 菱形中心＝對角中點
            local cy = (uy1 + uy3) / 2 - th / 2
            if cx >= 2 and cy >= 2 and cx + tw <= inner.width - 2 and cy + th <= inner.height - 2 then
                inner:drawRect(cx - 3, cy - 1, tw + 6, th + 2, 0.6, 0, 0, 0)
                inner:drawText(name, cx, cy, 1, 1, 1, 0.95, UIFont.Small)
            end
        end
    end
end

-- 世界地圖（M）同步畫框線：wrap prerender（原版 prerender＝ISWorldMap.lua:363）。
-- 時序同小地圖側（ISMiniMapInner:prerender）：引擎地圖畫在底、Lua prerender 疊加
-- 於其上，子元件（按鈕列/圖例/符號面板）之後才畫、蓋在最上——框線不遮 UI 控件
--（掛 render 會畫在子元件之後、蓋住按鈕列）。
if ISWorldMap and ISWorldMap.prerender then
    local originalWorldMapPrerender = ISWorldMap.prerender
    function ISWorldMap:prerender()
        originalWorldMapPrerender(self)
        pcall(drawMapBounds, self)
    end
end

--------------------------------------------------------------------------------
-- 導航目標：右鍵小地圖選單「設定/清除/分享導航目標」。目標在視窗內畫旗標、
-- 出視窗畫邊緣箭頭＋直線距離（確保方向感）；距目標 NAV_ARRIVE_DIST 格內自動
-- 抵達清除。自己的目標存 player modData 跨存檔持久；「分享給陣營」走
-- sendClientCommand → 伺服器端過濾同陣營逐一轉送
-- （media/lua/server/MinidoracatMiniMapServer.lua），對方以青旗＋名字顯示。
--------------------------------------------------------------------------------
-- navTargets（[playerNum] = {x=,y=}）已於檔案前段前置宣告
local navShared = {}       -- [playerNum] = true（處於分享狀態，清除/移動時須同步）
local sharedTargets = {}   -- [username] = {x=,y=}（同陣營成員分享來的，本場記憶）
local NAV_ARRIVE_DIST = 5  -- 抵達判定（世界格）

local function navSaveModData(playerObj, t)
    -- modData 隨角色存檔持久（IsoPlayer:getModData，Lua 泛用持久掛點）
    local md = playerObj:getModData()
    md.MinidoracatMiniMapTX = t and t.x or nil
    md.MinidoracatMiniMapTY = t and t.y or nil
    -- MP 的角色資料存在伺服器：本機改完要回傳，重連才載得到新值
    -- （transmitModData＝IsoPlayer.java:8716）
    if isClient() then playerObj:transmitModData() end
end

local function navClear(playerNum, playerObj)
    navTargets[playerNum] = nil
    navSaveModData(playerObj, nil)
    if navShared[playerNum] then
        navShared[playerNum] = nil
        if isClient() then
            sendClientCommand(playerObj, "MinidoracatMiniMap", "clearShared", {})
        end
    end
end

-- 右鍵選單回呼（addOption 簽名同原版 debug 傳送項 ISMiniMap.lua:292）
function ISMiniMapInner:onMinidoracatSetTarget(worldX, worldY)
    local pn = self.playerNum or 0
    local playerObj = getSpecificPlayer(pn)
    if not playerObj then return end
    navTargets[pn] = { x = worldX, y = worldY }
    navSaveModData(playerObj, navTargets[pn])
    if navShared[pn] then self:onMinidoracatShareTarget() end -- 分享中：移動即重新廣播
end

function ISMiniMapInner:onMinidoracatClearTarget()
    local pn = self.playerNum or 0
    local playerObj = getSpecificPlayer(pn)
    if playerObj then navClear(pn, playerObj) end
end

function ISMiniMapInner:onMinidoracatShareTarget()
    local pn = self.playerNum or 0
    local playerObj = getSpecificPlayer(pn)
    local t = navTargets[pn]
    if not (playerObj and t and isClient()) then return end
    if sandboxGate("AllowNavShare", true) == false then return end -- 伺服器沙盒禁用
    navShared[pn] = true
    sendClientCommand(playerObj, "MinidoracatMiniMap", "shareTarget", { x = t.x, y = t.y })
end

-- 旗標：黑框桿＋色旗（drawRect 疊法同殭屍點描邊）；label 掛旗上（分享者名字）
local function drawNavFlag(inner, ux, uy, r, g, b, label)
    inner:drawRect(ux - 2, uy - 14, 4, 15, 0.8, 0, 0, 0)
    inner:drawRect(ux - 1, uy - 13, 2, 13, 1, 1, 1, 1)
    inner:drawRect(ux, uy - 14, 11, 8, 0.8, 0, 0, 0)
    inner:drawRect(ux + 1, uy - 13, 9, 6, 1, r, g, b)
    if label then
        -- 深色底墊字（同原版玩家名牌做法 UIWorldMap.java:509），淺色地圖上才清晰；
        -- 位置夾進視窗（長名字貼上/右緣時不外溢），夾法同距離文字
        local tw = getTextManager():MeasureStringX(UIFont.Small, label)
        local w, h = inner.width, inner.height
        local lx, ly = ux + 4, uy - 30
        if lx < 2 then lx = 2 elseif lx > w - tw - 2 then lx = w - tw - 2 end
        if ly < 2 then ly = 2 elseif ly > h - 16 then ly = h - 16 end
        inner:drawRect(lx - 3, ly - 1, tw + 6, 16, 0.6, 0, 0, 0)
        inner:drawText(label, lx, ly, 1, 1, 1, 0.95, UIFont.Small) -- drawText＝ISUIElement.lua:1293
    end
end

-- 目標在視窗內＝旗標；出視窗＝中心→目標線段裁到內縮 12px 矩形（重用 clipSegment），
-- 交點畫 V 形箭頭（翼向量＝方向單位向量旋 ±25.8°，c=0.9/s=0.436，免 atan）
local function drawNavIndicator(inner, tx, ty, r, g, b, label, dist)
    local w, h = inner.width, inner.height
    if tx >= 8 and ty >= 16 and tx <= w - 14 and ty <= h - 4 then
        drawNavFlag(inner, tx, ty, r, g, b, label)
        return
    end
    local cx, cy = w / 2, h / 2
    local m = 12
    local sx1, sy1, sx2, sy2 = clipSegment(cx - m, cy - m, tx - m, ty - m, w - 2 * m, h - 2 * m)
    if not sx1 then return end
    local tipx, tipy = sx2 + m, sy2 + m
    local ddx, ddy = tx - cx, ty - cy
    local len = math.sqrt(ddx * ddx + ddy * ddy)
    if len < 1 then return end
    local uxn, uyn = ddx / len, ddy / len
    local c, s = 0.9, 0.436
    local b1x, b1y = uxn * c - uyn * s, uxn * s + uyn * c
    local b2x, b2y = uxn * c + uyn * s, -uxn * s + uyn * c
    inner:drawLine(nil, tipx, tipy, tipx - b1x * 11, tipy - b1y * 11, 2, 0.95, r, g, b)
    inner:drawLine(nil, tipx, tipy, tipx - b2x * 11, tipy - b2y * 11, 2, 0.95, r, g, b)
    local txt = label
    if dist then txt = tostring(dist) .. "m" end
    if txt then
        -- MeasureStringX 用例 ISFactionUI.lua:238
        local tw = getTextManager():MeasureStringX(UIFont.Small, txt)
        local px = tipx - uxn * 24 - tw / 2
        local py = tipy - uyn * 24 - 7
        if px < 2 then px = 2 elseif px > w - tw - 2 then px = w - tw - 2 end
        if py < 2 then py = 2 elseif py > h - 16 then py = h - 16 end
        -- 深色底墊字（同原版玩家名牌做法 UIWorldMap.java:509），淺色地圖上才清晰
        inner:drawRect(px - 3, py - 1, tw + 6, 16, 0.6, 0, 0, 0)
        inner:drawText(txt, px, py, 1, 1, 1, 0.95, UIFont.Small)
    end
end

local function drawNavTargets(inner)
    local pn = inner.playerNum or 0
    local mapAPI = inner.mapAPI
    local playerObj = getSpecificPlayer(pn)
    -- 陣營分享來的：只畫「給這位玩家」的桶（青旗＋名字）
    local bucket = playerObj and sharedTargets[playerObj:getUsername()]
    if bucket then
        for author, t in pairs(bucket) do
            drawNavIndicator(inner, mapAPI:worldToUIX(t.x, t.y), mapAPI:worldToUIY(t.x, t.y),
                0.2, 0.8, 1.0, author, nil)
        end
    end
    local t = navTargets[pn]
    if not t then return end
    if not playerObj then return end
    local ddx = t.x - playerObj:getX()
    local ddy = t.y - playerObj:getY()
    local dist = math.floor(math.sqrt(ddx * ddx + ddy * ddy) + 0.5)
    if dist <= NAV_ARRIVE_DIST then -- 抵達：自動清除（含分享清除通知）
        navClear(pn, playerObj)
        return
    end
    drawNavIndicator(inner, mapAPI:worldToUIX(t.x, t.y), mapAPI:worldToUIY(t.x, t.y),
        1.0, 0.85, 0.2, nil, dist) -- 自己＝金旗＋距離
end

-- 右鍵選單追加導航選項：原版 onRightMouseUp 以 ISContextMenu.get 建選單
-- （ISMiniMap.lua:280-298），get 會 clear（ISContextMenu.lua:1166-1170）——
-- 故以 getPlayerContextMenu 取同一單例追加（用例 ISContextMenu.lua:1167），
-- 不重呼 get、保住 debug 傳送選項；空選單原版以 numOptions==1 判定隱藏
-- （:295-297），追加後 >1 重新顯示
if ISMiniMapInner and ISMiniMapInner.onRightMouseUp then
    local originalInnerRightMouseUp = ISMiniMapInner.onRightMouseUp
    function ISMiniMapInner:onRightMouseUp(x, y)
        local wasDown = self.rightMouseDown -- 原版會消耗此旗標，先快照
        originalInnerRightMouseUp(self, x, y)
        if not wasDown then return end
        local pn = self.playerNum or 0
        local playerObj = getSpecificPlayer(pn)
        if not playerObj then return end
        -- 取 player 0 的單例：原版 onRightMouseUp 硬編碼 ISContextMenu.get(0,...)
        -- （ISMiniMap.lua:284-287），追加必須跟它同一個 menu
        local context = getPlayerContextMenu(0)
        local worldX = self.mapAPI:uiToWorldX(x, y) -- uiToWorld 用例 ISMiniMap.lua:289-290
        local worldY = self.mapAPI:uiToWorldY(x, y)
        context:addOption(getText("UI_MinidoracatMiniMap_SetTarget"), self,
            self.onMinidoracatSetTarget, worldX, worldY)
        if navTargets[pn] then
            context:addOption(getText("UI_MinidoracatMiniMap_ClearTarget"), self,
                self.onMinidoracatClearTarget)
            if isClient() and Faction and Faction.getPlayerFaction(playerObj)
                and sandboxGate("AllowNavShare", true) ~= false then
                -- Faction.getPlayerFaction 用例 ISFactionUI.lua:408
                context:addOption(getText("UI_MinidoracatMiniMap_ShareTarget"), self,
                    self.onMinidoracatShareTarget)
            end
        end
        if context.numOptions > 1 then context:setVisible(true) end
    end
end

-- 陣營分享接收（Events.OnServerCommand 用例 ServerCommands.lua:194）。
-- 以 args.to（收件角色名）分桶：同機分割畫面共用一條 connection，
-- 沒有 to 會讓非同陣營的本機玩家也看到座標
Events.OnServerCommand.Add(function(module, command, args)
    if module ~= "MinidoracatMiniMap" or not args then return end
    if command == "sharedTarget" and args.author and args.to and args.x and args.y then
        sharedTargets[args.to] = sharedTargets[args.to] or {}
        sharedTargets[args.to][args.author] = { x = args.x, y = args.y }
    elseif command == "clearShared" and args.author and args.to then
        local bucket = sharedTargets[args.to]
        if bucket then bucket[args.author] = nil end
    end
end)

if ISMiniMapInner and ISMiniMapInner.prerender then
    local originalInnerPrerender = ISMiniMapInner.prerender
    function ISMiniMapInner:prerender()
        originalInnerPrerender(self)
        -- 沙盒禁用殭屍熱度時每幀壓回；重新允許時恢復被壓的值（雙向即時）。
        -- 以實例旗標記住「是本閘門壓的」才恢復——不能對 ModOptions 值調和：
        -- 齒輪面板的熱度勾選是直寫引擎選項（僅當場生效的設計），逐幀調和會蓋掉它。
        -- 邊緣情況：壓制期間玩家在齒輪面板關掉熱度無法被辨識，重新允許時仍恢復為開
        if sandboxGate("AllowZombieIntensity", true) == false then
            if self.mapAPI:getBoolean("ZombieIntensity") then
                self._minidoracatZISuppressed = true
                self.mapAPI:setBoolean("ZombieIntensity", false)
            end
        elseif self._minidoracatZISuppressed then
            self._minidoracatZISuppressed = nil
            self.mapAPI:setBoolean("ZombieIntensity", true)
        end
        pcall(drawSafehouses, self) -- pcall 防清單併發增刪（同殭屍取樣的防禦策略）
        pcall(drawMapBounds, self)
        pcall(drawNavTargets, self)
        if not getBoolOption("ZombieDots", false) then return end -- 關閉＝零成本
        if sandboxGate("AllowZombieDots", true) == false then return end -- 伺服器沙盒禁用
        local st = sampleZombieDots(self) -- per-player 取樣狀態（分割畫面各自獨立）
        local c = ZDOTS_COLORS[getComboIndex("ZombieDotColor", 1)] or ZDOTS_COLORS[1]
        local size = ZDOTS_SIZES[getComboIndex("ZombieDotSize", 2)] or 3
        local mapAPI = self.mapAPI
        for i = 1, st.count do
            local d = st.dots[i]
            -- 世界→UI 座標：worldToUIX/Y＝UIWorldMapV1.java:298/311
            -- （mapAPI 是 getAPIv3，V3→V2→V1 繼承鏈 UIWorldMapV3.java:10、V2.java:8）；
            -- 原版用例 ISMultiplayerZoneEditor.lua:83 + MultiplayerZoneEditorMode_NonPVP.lua:58
            local ux = mapAPI:worldToUIX(d.x, d.y)
            local uy = mapAPI:worldToUIY(d.x, d.y)
            -- 手動裁到視窗內（Lua drawRect 不吃元件裁切）；含描邊起繪於 ux-2，
            -- 右/下界以 ux+size ≤ 邊長推得，免溢出 inner 疊到外框
            if ux >= 2 and uy >= 2 and ux <= self.width - size and uy <= self.height - size then
                -- drawRect＝ISUIElement.lua:1191（引數 x,y,w,h,a,r,g,b）；先黑底再填色＝描邊
                self:drawRect(ux - 2, uy - 2, size + 2, size + 2, ZDOTS_EDGE_A, 0, 0, 0)
                self:drawRect(ux - 1, uy - 1, size, size, ZDOTS_A, c[1], c[2], c[3])
            end
        end
    end
end

--------------------------------------------------------------------------------
-- 邊緣拖曳縮放 + HUD 視覺微調
-- 事件路由（UIElement.java:1015 onMouseDown：1047-1057 先讓子元件消化、
-- 沒人消化才輪到自己的 Lua handler 1096）：8px 熱區大多落在 outer 的子元件上——
--   左右緣＝inner 地圖（onMouseDown 回 true 消化，ISMiniMap.lua:226-237）、
--   上緣＝titleBar（消化並做移動，ISMiniMap.lua:363-369）、
--   下緣＝bottomPanel（ISPanel.lua:49 非 moveWithMouse 不消化→事件落回 outer）、
--   2px 外框環＝outer 自己。
-- 故共用一套熱區判定（outer 區域座標），hook ISMiniMapOuter / ISMiniMapInner /
-- ISMiniMapTitleBar 三個 class 的滑鼠事件（wrap 保留原行為；拖曳用 setCapture
-- 續收 Outside 事件，同 titleBar 做法 ISMiniMap.lua:367）。
-- 拖曳中只畫預覽外框，放開才以最終尺寸重建（走 InitPlayer wrapper 的
-- 自訂尺寸路徑），避免每幀重排版。
--------------------------------------------------------------------------------

local BRACKET_LEN = 14          -- 角落括號長度（px）
local BRACKET_THICK = 2         -- 角落括號粗細（px）
local HANDLE_ALPHA_IDLE = 0.35  -- 把手平時透明度（半透明白）
local HANDLE_ALPHA_HOVER = 0.9  -- 把手 hover／拖曳中透明度（PZ 改不了系統游標，靠這個給回饋）

local resizeState -- 進行中的拖曳（同時只會有一筆）：{ outer, edges, startMX, startMY, rect0, adornExtra, adorned, preview }

-- 以 outer 區域座標判定邊緣熱區；回傳 {l,r,t,b} 布林表（角落＝兩者皆真），不在熱區回 nil
local function hitResizeEdge(outer, ox, oy)
    if getBoolOption("LockPosition", false) then return nil end -- 鎖定＝停用邊緣縮放
    if ox < 0 or oy < 0 or ox > outer.width or oy > outer.height then return nil end
    local e = {
        l = ox <= RESIZE_EDGE,
        r = ox >= outer.width - RESIZE_EDGE,
        t = oy <= RESIZE_EDGE,
        b = oy >= outer.height - RESIZE_EDGE,
    }
    if e.l or e.r or e.t or e.b then return e end
    return nil
end

local function startResize(outer, edges, el)
    -- 幾何全用拖曳起點快照＋全域滑鼠座標（getMouseX/getMouseY 全域，
    -- ISUIElement:getMouseX 內部同源 ISUIElement.lua:339-343），
    -- 不受拖曳中 adornments（titleBar/bottomPanel）掀開收合影響
    local adorned = outer.titleBar ~= nil and outer.titleBar:isVisible()
    resizeState = {
        outer = outer,
        edges = edges,
        el = el, -- 起始捕捉的元件（cancelResize 清 capture/旗標用）
        startMX = getMouseX(),
        startMY = getMouseY(),
        rect0 = { x = outer:getAbsoluteX(), y = outer:getAbsoluteY(), w = outer.width, h = outer.height },
        -- 展開狀態的外框比基準尺寸高 titleBar + 1px + bottomPanel
        -- （setAdornmentsVisible 幾何，ISMiniMap.lua:479-497）
        adornExtra = adorned and (outer.titleBar.height + 1 + outer.bottomPanel.height) or 0,
        adorned = adorned,
        preview = { x = 0, y = 0, w = 0, h = 0 },
    }
    local p, r = resizeState.preview, resizeState.rect0
    p.x, p.y, p.w, p.h = r.x, r.y, r.w, r.h
end

local function updateResize()
    local st = resizeState
    if not st then return end
    local dx = getMouseX() - st.startMX
    local dy = getMouseY() - st.startMY
    local r0, e = st.rect0, st.edges
    local maxWH = resizeMax(st.outer.playerNum)
    local x, y, w, h = r0.x, r0.y, r0.w, r0.h
    if (e.l or e.r) and (e.t or e.b) then
        -- 角落＝等比縮放（問題 B）：以拖曳起點外框長寬比為基準，取對角位移的
        -- 主導軸（往外拖為正的增量中 |絕對值| 較大者）算比例，兩軸同乘
        local dw = e.l and -dx or dx
        local dh = e.t and -dy or dy
        local s
        if math.abs(dw) >= math.abs(dh) then
            s = (r0.w + dw) / r0.w
        else
            s = (r0.h + dh) / r0.h
        end
        -- 夾限作用在「比例」而非個別軸，兩軸夾完仍保持等比
        -- （寬限 [RESIZE_MIN, maxWH]；高含 adornments 增量再夾）
        local sMin = math.max(RESIZE_MIN / r0.w, (RESIZE_MIN + st.adornExtra) / r0.h)
        local sMax = math.min(maxWH / r0.w, (maxWH + st.adornExtra) / r0.h)
        s = math.max(sMin, math.min(sMax, s))
        w = r0.w * s
        h = r0.h * s
    else
        -- 單邊＝單軸自由縮放；拖哪邊動哪邊
        if e.l then w = w - dx elseif e.r then w = w + dx end
        if e.t then h = h - dy elseif e.b then h = h + dy end
        -- 夾限作用在「基準尺寸」（高度先扣 adornments 增量）
        w = math.max(RESIZE_MIN, math.min(maxWH, w))
        h = math.max(RESIZE_MIN + st.adornExtra, math.min(maxWH + st.adornExtra, h))
    end
    if e.l then x = r0.x + r0.w - w end -- 拖左緣：右緣錨定不動
    if e.t then y = r0.y + r0.h - h end -- 拖上緣：下緣錨定不動
    local p = st.preview
    p.x, p.y, p.w, p.h = x, y, w, h
end

local function endResize()
    local st = resizeState
    resizeState = nil
    if not st or not modOptions then return end
    local outer = st.outer
    local p = st.preview
    -- 取整：座標運算可能帶小數，寫入「寬x高」欄位須為整數（解析端只認 %d+）
    local baseW = math.floor(p.w + 0.5)
    local baseH = math.floor(p.h - st.adornExtra + 0.5)
    if baseW == st.rect0.w and baseH == st.rect0.h - st.adornExtra then return end -- 尺寸沒變，不重建
    if not getPlayerMiniMap(outer.playerNum) then return end -- Recreate 無 nil 防呆（AGENTS.md），先查
    local opt = modOptions:getOption("CustomSize")
    if not opt then return end
    -- 寫入自訂尺寸並立即落地 ModOptions.ini（PZAPI.ModOptions:save()＝ModOptions.lua:259）
    opt:setValue(baseW .. "x" .. baseH)
    PZAPI.ModOptions:save()
    -- 重建會重錨右下（AGENTS.md 已知行為）。若位置是使用者拖過的
    -- （userPosition 旗標，版面存讀同用 ISMiniMap.lua:660-670），重建後
    -- 還原成預覽框位置；baseY 是「收合狀態」的 y——收合時要加回 titleBar 高
    -- （展開時 setY(y - titleBar.height)，ISMiniMap.lua:487）。沒拖過就讓原版
    -- 重錨右下，視覺上與拖曳前一致（右下錨點本就不動）。
    local wasUserPosition = outer.userPosition
    local baseX = p.x
    local baseY = st.adorned and (p.y + outer.titleBar.height) or p.y
    ISMiniMap.Recreate(outer.playerNum) -- 走上方 hook 的 InitPlayer 自訂尺寸路徑
    local mm = getPlayerMiniMap(outer.playerNum)
    if mm and wasUserPosition then
        mm.userPosition = true
        mm:setX(baseX)
        -- 「永遠顯示」模式下重建後即是展開狀態，展開 y = 收合 y - titleBar 高
        if mm.titleBar and mm.titleBar:isVisible() then
            mm:setY(baseY - mm.titleBar.height)
        else
            mm:setY(baseY)
        end
    end
end

-- 取消進行中的拖曳並清理捕捉旗標（小地圖在拖曳中被移除——HOME 鍵/輪盤選單
-- Toggle——時 mouse up 永遠不會送達，不清會殘留「沒按鍵也跟著滑鼠縮放」的幽靈狀態）
function cancelResize()
    local st = resizeState
    resizeState = nil
    if st and st.el then
        st.el._minidoracatResizing = nil
        pcall(function() st.el:setCapture(false) end)
    end
end

-- 在指定 class（或實例——bottomPanel 是裸 ISPanel 只能掛實例）上包 resize
-- 滑鼠處理；toOuter 從該元件取得 outer。非熱區／非拖曳時一律走原 handler。
function installResizeHooks(class, toOuter)
    local origDown = class.onMouseDown
    function class:onMouseDown(x, y)
        if modOptions and not resizeState then -- 無 PZAPI（無法持久化）就不啟用縮放
            local outer = toOuter(self)
            if outer then
                -- 換算成 outer 區域座標（getAbsoluteX 用例 ISMiniMap.lua:287）
                local ox = x + self:getAbsoluteX() - outer:getAbsoluteX()
                local oy = y + self:getAbsoluteY() - outer:getAbsoluteY()
                local edges = hitResizeEdge(outer, ox, oy)
                if edges then
                    startResize(outer, edges, self)
                    self._minidoracatResizing = true
                    self:setCapture(true) -- 拖出元件外仍收 Move/Up（setCapture＝ISUIElement.lua:588）
                    return true -- 消化事件：不進原版（inner 地圖拖曳／titleBar 移動）
                end
            end
        end
        if origDown then return origDown(self, x, y) end
    end

    local origMove = class.onMouseMove
    function class:onMouseMove(dx, dy)
        if self._minidoracatResizing then
            updateResize()
            return true
        end
        if origMove then return origMove(self, dx, dy) end
    end

    local origMoveOutside = class.onMouseMoveOutside
    function class:onMouseMoveOutside(dx, dy)
        if self._minidoracatResizing then
            updateResize()
            return true
        end
        if origMoveOutside then return origMoveOutside(self, dx, dy) end
    end

    local function finishResize(el)
        el._minidoracatResizing = nil
        el:setCapture(false)
        endResize() -- 內含 Recreate，舊元件（含 el）之後被丟棄
        return true
    end

    local origUp = class.onMouseUp
    function class:onMouseUp(x, y)
        if self._minidoracatResizing then return finishResize(self) end
        if origUp then return origUp(self, x, y) end
    end

    local origUpOutside = class.onMouseUpOutside
    function class:onMouseUpOutside(x, y)
        if self._minidoracatResizing then return finishResize(self) end
        if origUpOutside then return origUpOutside(self, x, y) end
    end
end

-- 鎖定位置：擋標題列拖曳移動（原版 onMouseDown 起拖，ISMiniMap.lua:363-369）；
-- 邊緣縮放由 hitResizeEdge 開頭的鎖定檢查一併停用。回 true 消化事件，
-- 避免點擊落到 outer 觸發別的行為。
if ISMiniMapTitleBar and ISMiniMapTitleBar.onMouseDown then
    local originalTitleBarMouseDown = ISMiniMapTitleBar.onMouseDown
    function ISMiniMapTitleBar:onMouseDown(x, y)
        if getBoolOption("LockPosition", false) then return true end
        return originalTitleBarMouseDown(self, x, y)
    end
end

-- 點擊小地圖不再開世界地圖（預設）：原版 onMouseUp 無拖曳＝ToggleWorldMap
-- （ISMiniMap.lua:239-245）。選項 ClickOpenWorldMap 開啟時走原版。
-- 必須放在 installResizeHooks 之前 wrap：縮放 hook 要包在最外層（先吃縮放收尾，
-- 非縮放路徑才會落到這裡）。onMouseUpOutside 原版轉呼叫 onMouseUp（:247-249），同受控。
if ISMiniMapInner and ISMiniMapInner.onMouseUp then
    local originalInnerMouseUp = ISMiniMapInner.onMouseUp
    function ISMiniMapInner:onMouseUp(x, y)
        -- 拖曳自由查看：拖過＝停留在拖到的位置（下方 prerenderHack wrap 據
        -- 此旗標暫停回中）；點擊（無拖曳）＝回到玩家。選項關閉＝原版放開即回中
        if self.dragging and getBoolOption("FreeLook", true) then
            self._minidoracatFreelook = self.dragMoved or nil
        end
        if getBoolOption("ClickOpenWorldMap", false) then
            return originalInnerMouseUp(self, x, y)
        end
        self.dragging = false -- 原版拖曳收尾（ISMiniMap.lua:240-241），僅略過 ToggleWorldMap
    end
end

-- 自由查看的「停留」本體：原版 prerenderHack 每幀把地圖回中到玩家/載具
-- （ISMiniMap.lua:214-225，拖曳中才暫停）——自由查看旗標亮著就整段跳過
if ISMiniMapInner and ISMiniMapInner.prerenderHack then
    local originalPrerenderHack = ISMiniMapInner.prerenderHack
    function ISMiniMapInner:prerenderHack()
        if self._minidoracatFreelook and getBoolOption("FreeLook", true) then return end
        originalPrerenderHack(self)
    end
end

if ISMiniMapOuter and ISMiniMapInner and ISMiniMapTitleBar then
    installResizeHooks(ISMiniMapOuter, function(el) return el end)
    installResizeHooks(ISMiniMapInner, function(el) return el.parent end)
    installResizeHooks(ISMiniMapTitleBar, function(el) return el.miniMap end)
    -- bottomPanel 是裸 ISPanel 實例，在 InitPlayer hook 內逐實例補掛（見上方）

    -- 拖曳中小地圖被 Toggle 移除（HOME 鍵/世界地圖輪盤）→ mouse up 收不到，
    -- 先取消拖曳再走原版，避免幽靈縮放狀態
    if ISMiniMap and ISMiniMap.ToggleMiniMap then
        local originalToggleMiniMap = ISMiniMap.ToggleMiniMap
        function ISMiniMap.ToggleMiniMap(playerNum)
            if resizeState then cancelResize() end
            return originalToggleMiniMap(playerNum)
        end
    end
end

if ISMiniMapOuter and ISMiniMapOuter.prerender and ISMiniMapOuter.render then
    -- HUD 微調：整體 hover 時外框亮度 0.4→0.55（原版邊框色＝ISMiniMap.lua:676；
    -- prerender 以 borderColor 畫框＝ISMiniMap.lua:463）。不動背景、不加特效，
    -- 維持原版 OLED 深色高對比風格。
    local originalOuterPrerender = ISMiniMapOuter.prerender
    function ISMiniMapOuter:prerender()
        local hover = self:isMouseOver() or (resizeState ~= nil and resizeState.outer == self)
        local v = hover and 0.55 or 0.4
        self.borderColor.r, self.borderColor.g, self.borderColor.b = v, v, v
        originalOuterPrerender(self)
    end

    -- 角落括號＋邊緣亮條＋拖曳預覽框。掛 render：UIElement.java:1609 的 Lua render
    -- 在子元件（1604）之後呼叫，畫在整個小地圖最上層。
    local originalOuterRender = ISMiniMapOuter.render
    function ISMiniMapOuter:render()
        originalOuterRender(self)
        if not modOptions then return end -- 縮放未啟用就不畫把手
        local st = (resizeState ~= nil and resizeState.outer == self) and resizeState or nil
        local hoverEdges = nil
        if st then
            hoverEdges = st.edges
        elseif self:isMouseOver() then
            hoverEdges = hitResizeEdge(self, self:getMouseX(), self:getMouseY())
        end
        -- 把手只在 adornments 展開（滑鼠在小地圖上）或拖曳中顯示，平常零干擾；
        -- 鎖定時縮放已停用（hitResizeEdge 回 nil），括號一併不畫免誤導
        if (st or (self.titleBar and self.titleBar:isVisible()))
            and not getBoolOption("LockPosition", false) then
            local w, h = self.width, self.height
            local L, T = BRACKET_LEN, BRACKET_THICK
            local aTL = (hoverEdges and (hoverEdges.l or hoverEdges.t)) and HANDLE_ALPHA_HOVER or HANDLE_ALPHA_IDLE
            local aTR = (hoverEdges and (hoverEdges.r or hoverEdges.t)) and HANDLE_ALPHA_HOVER or HANDLE_ALPHA_IDLE
            local aBL = (hoverEdges and (hoverEdges.l or hoverEdges.b)) and HANDLE_ALPHA_HOVER or HANDLE_ALPHA_IDLE
            local aBR = (hoverEdges and (hoverEdges.r or hoverEdges.b)) and HANDLE_ALPHA_HOVER or HANDLE_ALPHA_IDLE
            self:drawRect(0, 0, L, T, aTL, 1, 1, 1)         -- 左上括號
            self:drawRect(0, 0, T, L, aTL, 1, 1, 1)
            self:drawRect(w - L, 0, L, T, aTR, 1, 1, 1)     -- 右上括號
            self:drawRect(w - T, 0, T, L, aTR, 1, 1, 1)
            self:drawRect(0, h - T, L, T, aBL, 1, 1, 1)     -- 左下括號
            self:drawRect(0, h - L, T, L, aBL, 1, 1, 1)
            self:drawRect(w - L, h - T, L, T, aBR, 1, 1, 1) -- 右下括號
            self:drawRect(w - T, h - L, T, L, aBR, 1, 1, 1)
            if hoverEdges then -- hover 的邊畫亮條
                if hoverEdges.l then self:drawRect(0, 0, 2, h, HANDLE_ALPHA_HOVER, 1, 1, 1) end
                if hoverEdges.r then self:drawRect(w - 2, 0, 2, h, HANDLE_ALPHA_HOVER, 1, 1, 1) end
                if hoverEdges.t then self:drawRect(0, 0, w, 2, HANDLE_ALPHA_HOVER, 1, 1, 1) end
                if hoverEdges.b then self:drawRect(0, h - 2, w, 2, HANDLE_ALPHA_HOVER, 1, 1, 1) end
            end
        end
        if st then -- 拖曳中只畫預覽外框（drawRectBorder 用例 ISMiniMap.lua:474）
            local px = st.preview.x - self:getAbsoluteX()
            local py = st.preview.y - self:getAbsoluteY()
            self:drawRectBorder(px, py, st.preview.w, st.preview.h, HANDLE_ALPHA_HOVER, 1, 1, 1)
            self:drawRectBorder(px + 1, py + 1, st.preview.w - 2, st.preview.h - 2, 0.4, 1, 1, 1)
        end
    end
end

-- 快捷鍵：小地圖開關（選項 → 按鍵綁定 → [MinidoracatMiniMap] 可改鍵）。
-- 預設 HOME（原版 keyBinding.lua 無此鍵衝突；N 撞 StartVehicleEngine 故不用）。
-- ToggleMiniMap 自帶防呆：沙盒未開 AllowMiniMap 時 getPlayerMiniMap 為 nil、直接略過。
local function initBinds()
    table.insert(keyBinding, { value = "[MinidoracatMiniMap]" })
    table.insert(keyBinding, { value = "MinidoracatMiniMap_Toggle", key = Keyboard.KEY_HOME })
end
Events.OnGameBoot.Add(initBinds)

local function onKeyPressed(key)
    if key ~= getCore():getKey("MinidoracatMiniMap_Toggle") then return end
    if not (ISMiniMap and ISMiniMap.ToggleMiniMap) then return end
    if not getSpecificPlayer(0) then return end -- 主選單等無玩家情境
    -- 不受沙盒 AllowMiniMap 限制：原版沒建小地圖時（getPlayerMiniMap 為 nil）
    -- 照 ISMiniMap.Recreate 的做法自己建（經過我們 hook 的 InitPlayer 會套 pyramid）。
    if not getPlayerMiniMap(0) then
        local ok, err = pcall(function()
            getPlayerData(0).miniMap = ISMiniMap.InitPlayer(0)
        end)
        if not ok then
            log("小地圖建立失敗: " .. tostring(err))
            return
        end
        -- InitPlayer 在 MiniMap.StartVisible=true 時已直接顯示，此時再 toggle 會關掉
        local mm = getPlayerMiniMap(0)
        if mm and mm:isReallyVisible() then return end
    end
    ISMiniMap.ToggleMiniMap(0)
end
Events.OnKeyPressed.Add(onKeyPressed)

-- 原版 bug 防呆：存檔缺 mods.txt（如測試時強關遊戲的頭幾秒）時
-- saveInfo.activeMods 為 nil，MainScreen.getMissingMods 沒 nil 防呆會讓
-- 「繼續遊戲」直接報錯（呼叫端 continueLatestSaveAux 1188 行本就預期 nil）。
if MainScreen and MainScreen.getMissingMods then
    local originalGetMissingMods = MainScreen.getMissingMods
    function MainScreen.getMissingMods(activeMods)
        if not activeMods then return {} end
        return originalGetMissingMods(activeMods)
    end
end

log("已載入（hook ISWorldMap:initDataAndStyle + ISMiniMap.InitPlayer + 按鈕列模式 + 齒輪面板 + 快捷鍵 + MOD 選項 + 殭屍點位 + 邊緣縮放）")
