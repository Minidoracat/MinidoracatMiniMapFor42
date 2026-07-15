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
local MAPS = {
    { zip = "Muldraugh_KY.pyramid.zip" }, -- 基底全圖（B42 主世界）
}

-- MOD 地圖包註冊 API（地圖包 addon 專用，如 MinidoracatMiniMapModMapsFor42）：
-- 地圖包在自己的 client lua 呼叫（mod.info require=本 MOD 保證本檔先載入）：
--   MinidoracatMiniMapAPI.registerMaps("<地圖包自身 mod ID>", {
--       { zip = "<地圖名>.pyramid.zip", mapMod = "<該地圖 MOD 的 mod ID>",
--         bounds = { x1, y1, x2, y2 }, nameKey = "UI_..." }, ...
--   })
-- zip 放地圖包自己的 media/minimap/；bounds＝渲染時 pyramid.txt 的世界 square
-- 座標（右/下排他，cell*256，MinidoracatMapRendering/src/pyramid.rs:179-186）；
-- nameKey 缺譯退 mapMod。同地圖多 mod ID 變體＝同 zip/bounds 多條目（掛載去重）。
local registeredPacks = {} -- { { owner = <地圖包 mod ID>, entries = {...} }, ... }
MinidoracatMiniMapAPI = MinidoracatMiniMapAPI or {}
function MinidoracatMiniMapAPI.registerMaps(ownerModId, entries)
    if type(ownerModId) ~= "string" or ownerModId == "" or type(entries) ~= "table" then
        print("[MinidoracatMiniMap] registerMaps 參數錯誤（需 ownerModId, entries）")
        return
    end
    -- 逐條驗證、壞條目跳過並 log：掛載/繪製端信任這裡的把關，
    -- 單一壞條目不能拖垮整包（外部地圖包作者的輸入＝信任邊界）
    local valid = {}
    for i, e in ipairs(entries) do
        local ok = type(e) == "table" and type(e.zip) == "string" and e.zip ~= ""
            and (e.mapMod == nil or type(e.mapMod) == "string")
            and (e.nameKey == nil or type(e.nameKey) == "string")
        if ok and e.bounds ~= nil then
            ok = type(e.bounds) == "table" and #e.bounds == 4
            if ok then
                for j = 1, 4 do
                    if type(e.bounds[j]) ~= "number" then
                        ok = false
                        break
                    end
                end
            end
        end
        if ok then
            table.insert(valid, e)
        else
            print("[MinidoracatMiniMap] registerMaps: 略過無效條目 #" .. i .. "（來源 " .. ownerModId .. "）")
        end
    end
    if #valid > 0 then -- 空包不註冊：地圖包選項不該因空資料出現
        table.insert(registeredPacks, { owner = ownerModId, entries = valid })
    end
end

-- MOD 地圖框線繪製資料（collectPyramids 於地圖初始化時重建；drawMapBounds 每幀讀）
local mapOverlays = {}

-- 第三方 addon 相容約定檔名（零 Lua）：地圖 MOD 自附 minimap 支援時使用
local LEGACY_CANONICAL = "minidoracat_minimap.pyramid.zip"

local function log(msg)
    print("[MinidoracatMiniMap] " .. tostring(msg))
end

-- 前置宣告（定義在下方 ModOptions 一節）：collectPyramids 的地圖包段要讀
-- MapPackLayers 選項——Lua 區域名稱僅宣告後可見，不前置宣告會誤綁全域（nil）
local getBoolOption

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
    -- 來源＝已註冊地圖包；有 bounds 且對應地圖 MOD 啟用者才畫框——
    -- 框線不依賴 zip 是否渲染，也不受「顯示 MOD 地圖區塊」開關影響（定位用）
    for i = #mapOverlays, 1, -1 do mapOverlays[i] = nil end
    for _, pack in ipairs(registeredPacks) do
        for _, entry in ipairs(pack.entries) do
            if entry.bounds and entry.mapMod and active[entry.mapMod] then
                table.insert(mapOverlays, entry)
            end
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

    -- (1b) 已註冊地圖包：zip 在地圖包自己的 media/minimap/。
    -- 「顯示 MOD 地圖區塊」（MapPackLayers，地圖包裝了才有的選項）關閉時整段跳過
    -- ——生效時機＝地圖重建（齒輪/選項頁改動會觸發小地圖 Recreate）
    if getBoolOption("MapPackLayers", true) then
        for _, pack in ipairs(registeredPacks) do
            local ownerInfo = getModInfoByID(pack.owner)
            if ownerInfo then
                for _, entry in ipairs(pack.entries) do
                    if not entry.mapMod or active[entry.mapMod] then
                        local path = findZip(ownerInfo, sep, entry.zip)
                        if path then
                            table.insert(list, { path = path, zip = entry.zip })
                        else
                            log("地圖包 " .. pack.owner .. " 缺 " .. entry.zip .. "（漏渲染或漏打包？）")
                        end
                    end
                end
            else
                log("地圖包 mod ID 無效: " .. tostring(pack.owner) .. "（registerMaps 第一參數需為地圖包自身 mod ID）")
            end
        end
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
    end

    -- 樣式層：疊在原版樣式之上，不清空原版（刻意不學 showTerrainImage 的 styleAPI:clear()）。
    -- 每個「檔名」一層（引擎一層只綁一個檔名）；防重複註冊：圖層已存在就不重加。
    -- log 只在真正新增圖層時輸出——本函式會被開圖/樣式重建冪等重跑，無條件 log 會刷屏
    local added = 0
    for _, e in ipairs(entries) do
        local layerId = "minidoracat_" .. (e.zip:gsub("%.pyramid%.zip$", ""))
        if styleAPI:indexOfLayer(layerId) == -1 then
            local layer = styleAPI:newPyramidLayer(layerId)
            layer:setPyramidFileName(e.zip)
            layer:addFill(0.0, 255.0, 255.0, 255.0, 255.0)
            added = added + 1
            log("已掛載 pyramid: " .. e.path)
        end
    end

    mapAPI:setBoolean("ImagePyramid", true)
    if added > 0 then
        log("圖層就緒（新增 " .. added .. "／共 " .. #entries .. " 個 pyramid zip）")
    end
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

getBoolOption = function(id, default) -- 本體（前置宣告見檔案上方）
    if not modOptions then return default end
    local opt = modOptions:getOption(id)
    if opt == nil then return default end
    return opt:getValue()
end

-- 沙盒管理閘門（media/sandbox-options.txt 定義）：客戶端每幀讀值——
-- 管理員沙盒面板改動同步後即時生效；缺表/缺鍵時回呼叫端提供的 default
local function sandboxGate(name, default)
    local sb = SandboxVars and SandboxVars.MinidoracatMiniMap
    local v = sb and sb[name]
    if v == nil then return default end
    return v
end

-- 距離沙盒值 0 或缺值＝不限制；僅正數啟用距離閘門
-- test:sandbox-distance:start
local function sandboxDist(name)
    local v = sandboxGate(name, 0)
    if type(v) == "number" and v > 0 then return v end
    return nil
end
-- test:sandbox-distance:end

-- 牲畜可見性：1=全部、2=隱藏其他安全屋內、3=僅我方安全屋內、4=全部隱藏。
-- 單機沒有可用的玩家間安全屋歸屬語意，前 3 檔等同全部顯示；第 4 檔仍有效。
-- test:livestock-effective-mode:start
local function livestockVisibilityMode()
    local mode = sandboxGate("LivestockVisibility", 2)
    if type(mode) ~= "number" or mode < 1 or mode > 4 then mode = 2 end
    if not isClient() and mode ~= 4 then return 1 end
    return mode
end
-- test:livestock-effective-mode:end

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

-- 圖標染色下拉的共用項目序（＝繪製端 ADOTS_PALETTE 索引，兩表順序必須一致）：
-- Okabe-Ito 色盲友善色系（紅綠色盲下八色仍可辨），綠/天藍沿用實測亮度
local ADOTS_COLOR_ITEMS = {
    "UI_MinidoracatMiniMap_IColor_White", "UI_MinidoracatMiniMap_IColor_Green",
    "UI_MinidoracatMiniMap_IColor_Orange", "UI_MinidoracatMiniMap_IColor_Sky",
    "UI_MinidoracatMiniMap_IColor_Yellow", "UI_MinidoracatMiniMap_IColor_Magenta",
    "UI_MinidoracatMiniMap_IColor_Blue", "UI_MinidoracatMiniMap_IColor_Vermilion",
}

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
    -- 地圖包（MapPackLayers/MapBounds/MapBoundsColor）選項為 addon-conditional，
    -- 於下方 OnGameBoot 區塊「有地圖包註冊」時才追加——沒裝地圖包不出現
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
    -- 動物圖標（預設關）：野生/畜養獨立開關＋風格/尺寸（繪製端每幀讀值，存檔即生效）
    modOptions:addTickBox("AnimalWild", "UI_MinidoracatMiniMap_AnimalWild", false,
        "UI_MinidoracatMiniMap_AnimalWild_tooltip")
    modOptions:addTickBox("AnimalLivestock", "UI_MinidoracatMiniMap_AnimalLivestock", false,
        "UI_MinidoracatMiniMap_AnimalLivestock_tooltip")
    local aStyleCombo = modOptions:addComboBox("AnimalIconStyle", "UI_MinidoracatMiniMap_AnimalIconStyle")
    aStyleCombo:addItem("UI_MinidoracatMiniMap_AIconStyle_Symbol", true) -- 預設地圖符號
    aStyleCombo:addItem("UI_MinidoracatMiniMap_AIconStyle_Item", false)
    local aSizeCombo = modOptions:addComboBox("AnimalIconSize", "UI_MinidoracatMiniMap_AnimalIconSize")
    aSizeCombo:addItem("UI_MinidoracatMiniMap_ZDotSize_Small", false) -- 小/中/大字樣沿用 ZDotSize 鍵
    aSizeCombo:addItem("UI_MinidoracatMiniMap_ZDotSize_Medium", true)
    aSizeCombo:addItem("UI_MinidoracatMiniMap_ZDotSize_Large", false)
    -- 載具圖標（預設關）：無內建車形地圖圖示，以方向盤符號顯示（見 ADOTS_VEH_SYM）
    modOptions:addTickBox("VehicleDots", "UI_MinidoracatMiniMap_VehicleDots", false,
        "UI_MinidoracatMiniMap_VehicleDots_tooltip")
    -- 篩選停用清單（統一視窗的物種/載具類別勾選自動寫入；CSV、空＝全開）。
    -- PZAPI 無多選元件，做成可見進階欄位（同 CustomSize 先例）——一般玩家用視窗操作
    modOptions:addTextEntry("AnimalSpeciesFilter", "UI_MinidoracatMiniMap_AnimalSpeciesFilter", "",
        "UI_MinidoracatMiniMap_AnimalSpeciesFilter_tooltip")
    modOptions:addTextEntry("VehicleCategoryFilter", "UI_MinidoracatMiniMap_VehicleCategoryFilter", "",
        "UI_MinidoracatMiniMap_VehicleCategoryFilter_tooltip")
    -- 圖標染色三下拉（玩家偏好/色盲需求；繪製端每幀讀值即時生效）
    local function addColorCombo(id, labelKey, defaultIdx)
        local c = modOptions:addComboBox(id, labelKey)
        for i = 1, #ADOTS_COLOR_ITEMS do c:addItem(ADOTS_COLOR_ITEMS[i], i == defaultIdx) end
    end
    addColorCombo("AnimalWildColor", "UI_MinidoracatMiniMap_AnimalWildColor", 2)      -- 預設綠
    addColorCombo("AnimalLivestockColor", "UI_MinidoracatMiniMap_AnimalLivestockColor", 1) -- 預設白
    addColorCombo("VehicleIconColor", "UI_MinidoracatMiniMap_VehicleIconColor", 4)    -- 預設天藍
    -- 世界地圖（M）獨立圖標開關（預設關）：風格/顏色/物種與類別篩選共用小地圖設定
    modOptions:addTickBox("WMZombieDots", "UI_MinidoracatMiniMap_WMZombieDots", false,
        "UI_MinidoracatMiniMap_WM_tooltip")
    modOptions:addTickBox("WMAnimalWild", "UI_MinidoracatMiniMap_WMAnimalWild", false,
        "UI_MinidoracatMiniMap_WM_tooltip")
    modOptions:addTickBox("WMAnimalLivestock", "UI_MinidoracatMiniMap_WMAnimalLivestock", false,
        "UI_MinidoracatMiniMap_WM_tooltip")
    modOptions:addTickBox("WMVehicleDots", "UI_MinidoracatMiniMap_WMVehicleDots", false,
        "UI_MinidoracatMiniMap_WM_tooltip")
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
        if (mm._minidoracatPackLayers == true) ~= (getBoolOption("MapPackLayers", true) == true) then
            ISMiniMap.Recreate(0) -- 地圖包圖層開關改動：重建以重新決定掛載/建層
        elseif mm._minidoracatSizeIndex ~= getSizeIndex() then
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
-- 註：初建其實也會經內部 overlayPaper 觸發下方 wrap 補掛（instance 於
-- ISWorldMap.lua:1506 先賦值、:1514 才 init）——此處是刻意冗餘的顯式主掛載點，
-- 不依賴「initDataAndStyle 內部一定呼叫 overlayPaper」這個原版細節。
local originalInitDataAndStyle = ISWorldMap.initDataAndStyle
function ISWorldMap:initDataAndStyle()
    originalInitDataAndStyle(self)
    local ok, err = pcall(applyMiniMapPyramids, self)
    if not ok then
        log("初始化失敗: " .. tostring(err))
    end
end

-- 樣式重建黏著（實測回饋：世界地圖沒有 MOD 地圖圖案）：原版會在遊戲中途重跑
-- initDefaultStyleV3＋overlayPaper 把本 MOD 圖層洗掉——觸發點：prerender 的
-- 色盲圖案不同步偵測（ISWorldMap.lua:367-370，切過無障礙選項/地圖面板勾選即中）、
-- debug 右鍵「Reapply Style」（:933-937）、TerrainImage 關閉（:1067-1068）。
-- 世界地圖是單例、initDataAndStyle 只跑一次，洗掉後不重啟不會復原。
-- 修法＝wrap overlayPaper（洗圖層路徑都是 V3+overlayPaper 成對，掛 paper 之後
-- 補圖層順序才正確）＋identity 只補世界地圖單例——LootMaps 紙本地圖物品
-- 也走 V3/overlayPaper，但傳入自己的 mapUI、不匹配 ISWorldMap_instance，
-- 不受污染（先前不 hook V3 的顧慮就是它）。addImagePyramid 去重＋
-- indexOfLayer 防重複，重複補掛安全。
-- 已知盲點：showTerrainImage（TerrainImage 開，:1073-1080）走 styleAPI:clear()
-- 且不配 overlayPaper，本 wrap 攔不到——TERRAIN_IMAGE=getDebug()（:10）
-- debug-only，正常遊玩不觸發，不處理
if MapUtils and MapUtils.overlayPaper then
    local originalOverlayPaper = MapUtils.overlayPaper
    function MapUtils.overlayPaper(mapUI)
        originalOverlayPaper(mapUI)
        if ISWorldMap_instance and mapUI == ISWorldMap_instance then
            local ok, err = pcall(applyMiniMapPyramids, mapUI)
            if not ok then
                log("世界地圖樣式重建後補掛失敗: " .. tostring(err))
            end
        end
    end
end

-- 開圖保險：每次 ShowWorldMap 後補掛一次（冪等：addImagePyramid 去重＋
-- indexOfLayer 防重複）。實測仍出現過「開圖當下圖層已缺失、按 debug
-- Reapply Style 才回來」——上方 overlayPaper wrap 攔得住所有打到單例的
-- overlayPaper 呼叫；實測仍缺圖代表另有成因（不走 overlayPaper 的洗層路徑，
-- 或 applyMiniMapPyramids 某次間歇失敗、如 collectPyramids 暫時回空），
-- 尚未定位，開圖補掛把可見缺圖窗口歸零。成本＝每次開圖一次、非每幀。
-- 簽名同原版（ISWorldMap.lua:1500）
if ISWorldMap and ISWorldMap.ShowWorldMap then
    local originalShowWorldMap = ISWorldMap.ShowWorldMap
    function ISWorldMap.ShowWorldMap(playerNum, centerX, centerY, zoom)
        originalShowWorldMap(playerNum, centerX, centerY, zoom)
        if ISWorldMap_instance then
            local ok, err = pcall(applyMiniMapPyramids, ISWorldMap_instance)
            if not ok then
                log("開圖補掛失敗: " .. tostring(err))
            end
        end
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
            minimap._minidoracatPackLayers = getBoolOption("MapPackLayers", true) -- 同上：地圖包圖層開關
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
        if isClient() then -- 隊友圖標僅多人顯示；名字（PlayerNames）不給獨立勾選框：
            -- 它無 ModOptions 項、隨 RemotePlayers 連動（applyToggleOptions 與
            -- 面板 onTickBox 皆同寫），獨立勾了也會被下次套用蓋回
            table.insert(names, "RemotePlayers")
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

-- 齒輪面板引擎選項勾選的兩件補課（原版 onTickBox 對一般項只寫單一引擎選項值
-- ——ColorblindPatterns 特例除外，ISMiniMap.lua:14-20；我們注入的殭屍點位等
-- tickbox 走自訂 handler 不經此處）：
-- 1. 耦合選項即時連動：勾「地名」連帶開「符號」、切「隊友圖標」同寫「隊友名字」
--    ——同 applyToggleOptions 的耦合，補面板的即時路徑。
-- 2. 「ESC 選項頁也有同名項」的引擎開關回寫 ModOptions——引擎值僅活在記憶體，
--    不回寫則之後任何 applyToggleOptions（改尺寸/顏色等設定套用、重建）都會拿
--    ModOptions 舊值把面板勾選蓋回去（玩家實測：面板關熱度後一調設定就被勾回）。
--    耦合先做、回寫在後：save() 寫檔失敗拋錯時不可綁架耦合。
-- 同步表與 getVisibleOptions 注入清單一一對應——新增注入項時兩處要一起改。
local PANEL_MODOPTION_SYNC = {
    Players = true, RemotePlayers = true, ZombieIntensity = true, PlaceNames = true,
}
if ISMiniMapOptionsPanel and ISMiniMapOptionsPanel.onTickBox then
    local originalPanelOnTickBox = ISMiniMapOptionsPanel.onTickBox
    function ISMiniMapOptionsPanel:onTickBox(index, selected, option)
        originalPanelOnTickBox(self, index, selected, option)
        local name = option and option.getName and option:getName()
        if selected and name == "PlaceNames" then
            self.map.mapAPI:setBoolean("Symbols", true)
            self:synchUI() -- 讓「符號」勾選框立即反映（synchUI＝ISMiniMap.lua:128）
        elseif name == "RemotePlayers" then
            self.map.mapAPI:setBoolean("PlayerNames", selected) -- 名字隨圖標（同 applyToggleOptions）
            self:synchUI() -- debug/admin 全量面板列有 PlayerNames，讓其勾選框即時反映
        end
        if modOptions and name and PANEL_MODOPTION_SYNC[name] then
            local opt = modOptions:getOption(name)
            if opt then
                opt:setValue(selected) -- 同步 ESC 選項頁元件（ModOptions.lua:68-73）
                PZAPI.ModOptions:save() -- 立即落地 ini（同 onMinidoracatTick 做法）
            end
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
        { id = "AnimalWild", label = "UI_MinidoracatMiniMap_AnimalWild", default = false },
        { id = "AnimalLivestock", label = "UI_MinidoracatMiniMap_AnimalLivestock", default = false },
        { id = "VehicleDots", label = "UI_MinidoracatMiniMap_VehicleDots", default = false },
        { id = "StreetNames", label = "UI_MinidoracatMiniMap_StreetNames", default = true,
            apply = function(panel, selected)
                if panel.map and panel.map.mapAPI then
                    panel.map.mapAPI:setBoolean("ShowStreetNames", selected)
                end
            end },
        { id = "Safehouses", label = "UI_MinidoracatMiniMap_Safehouses", default = true },
        { id = "LockPosition", label = "UI_MinidoracatMiniMap_LockPosition", default = false },
    }

    -- 地圖包 addon 專屬齒輪項（有註冊才加；OnGameBoot＝所有 MOD lua 載完，
    -- 齒輪面板 createChildren 於遊戲內執行、遠晚於此）。
    -- MapPackLayers 的 apply＝重建小地圖重新掛載（掛載/建層在 init 時決定）；
    -- Recreate 無 nil 防呆，呼叫前必查 getPlayerMiniMap（AGENTS.md 鐵則）
    Events.OnGameBoot.Add(function()
        if #registeredPacks == 0 then return end
        table.insert(GEAR_TICKS, { id = "MapPackLayers",
            label = "UI_MinidoracatMiniMap_MapPackLayers", default = true,
            apply = function(panel, selected)
                if getSpecificPlayer(0) and getPlayerMiniMap(0) then
                    ISMiniMap.Recreate(0)
                end
            end })
        table.insert(GEAR_TICKS, { id = "MapBounds",
            label = "UI_MinidoracatMiniMap_MapBounds", default = true })
    end)

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
        local livestockMode = livestockVisibilityMode()
        self._minidoracatLivestockMode = livestockMode
        local maxRight = self.width
        for i = 1, #GEAR_TICKS do
            local entry = GEAR_TICKS[i]
            -- ISTickBox:new(x,y,w,h,name,target,method,arg)＝ISTickBox.lua:282；用法同 ISMiniMap.lua:48
            local tickBox = ISTickBox:new(xPad, y, self.width, entryHgt, "", self,
                self.onMinidoracatTick, entry)
            tickBox:initialise()
            local label = getTextOrNull(entry.label) or entry.id
            if entry.id == "AnimalLivestock" and livestockMode == 4 then
                label = label .. ": " .. getText("UI_MinidoracatMiniMap_LivestockHiddenBySandbox")
            end
            tickBox:addOption(label) -- addOption＝ISTickBox.lua:227
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

    -- 沙盒值可由管理員即時同步；模式跨入/離開 4 時強制走原版重建路徑，
    -- 避免已開啟的齒輪面板沿用 createChildren 當下的舊警示文字。
    local originalPanelPrerender = ISMiniMapOptionsPanel.prerender
    function ISMiniMapOptionsPanel:prerender()
        local mode = livestockVisibilityMode()
        if self._minidoracatLivestockMode ~= nil and self._minidoracatLivestockMode ~= mode then
            self.screenHeight = -1 -- 讓 originalPanelSynchUI 清子元件並重跑 createChildren
            self:synchUI()
        end
        originalPanelPrerender(self)
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
        -- 原生三項跨重建快照：原版 Recreate 砍舊建新（ISMiniMap.lua:778-781）且
        -- 不先 saveSettings（那要等玩家資料拆除，ISPlayerData.lua:59）——本場剛在
        -- 統一視窗改的等軸測/符號/遠端符號會被 restoreSettings 的舊檔值蓋掉
        local snap
        local api = mm and mm.inner and mm.inner.mapAPI
        if api then
            snap = {
                Isometric = api:getBoolean("Isometric"),
                Symbols = api:getBoolean("Symbols"),
                RemoteSymbols = api:getBoolean("RemoteSymbols"),
            }
        end
        local result = originalRecreate(playerNum)
        if snap then
            local nmm = getPlayerMiniMap(playerNum)
            local napi = nmm and nmm.inner and nmm.inner.mapAPI
            if napi then
                napi:setBoolean("Isometric", snap.Isometric)
                napi:setBoolean("Symbols", snap.Symbols)
                napi:setBoolean("RemoteSymbols", snap.RemoteSymbols)
            end
        end
        return result
    end
end

--------------------------------------------------------------------------------
-- 統一控制視窗＋按鈕列擴充（免跑 ESC 選項頁）：
--   齒輪鈕開啟；五個可收合區塊（圖層/殭屍點位/動物/載具/外觀行為）整併
--   原設定視窗與圖層面板注入項——「=」鈕已退役，引擎原生三項
--   （等軸測/符號/遠端符號）移入「圖層顯示」區。
-- 視窗以 ISCollapsableWindow 頂層呈現（標題拖曳＋關閉鈕內建，
-- ISCollapsableWindow.lua:26-61），改值即寫回 ModOptions（同步 ESC 頁元件，
-- ModOptions.lua:68-73）並走既有 modOptions:apply()——尺寸重建/開關即時/
-- 透明度一條龍，不另寫套用邏輯。收合/展開/全選採「全清重建」模式
-- （同原版 synchUI 全重建先例，ISMiniMap.lua:133-142），免逐元件同步。
--------------------------------------------------------------------------------
-- 前置宣告（本體見下方「動物圖標」一節；視窗畫物種小圖用）
local adotsTexture, ADOTS_ART

-- 物種/載具類別篩選（統一視窗勾選；CSV 存「停用」鍵、空字串＝全開）。
-- 鼠類 UI 上合併 rat+mouse（圖標也共用 map_rodent）
local ADOTS_SPECIES_UI = {
    { key = "cow",     label = "UI_MinidoracatMiniMap_Sp_Cow",     groups = { "cow" } },
    { key = "sheep",   label = "UI_MinidoracatMiniMap_Sp_Sheep",   groups = { "sheep" } },
    { key = "pig",     label = "UI_MinidoracatMiniMap_Sp_Pig",     groups = { "pig" } },
    { key = "deer",    label = "UI_MinidoracatMiniMap_Sp_Deer",    groups = { "deer" } },
    { key = "chicken", label = "UI_MinidoracatMiniMap_Sp_Chicken", groups = { "chicken" } },
    { key = "turkey",  label = "UI_MinidoracatMiniMap_Sp_Turkey",  groups = { "turkey" } },
    { key = "rabbit",  label = "UI_MinidoracatMiniMap_Sp_Rabbit",  groups = { "rabbit" } },
    { key = "raccoon", label = "UI_MinidoracatMiniMap_Sp_Raccoon", groups = { "raccoon" } },
    { key = "rodent",  label = "UI_MinidoracatMiniMap_Sp_Rodent",  groups = { "rat", "mouse" } },
}
local ADOTS_VEHCAT_UI = {
    { key = "standard", label = "UI_MinidoracatMiniMap_VCat_Standard" },
    { key = "heavy",    label = "UI_MinidoracatMiniMap_VCat_Heavy" },
    { key = "sport",    label = "UI_MinidoracatMiniMap_VCat_Sport" },
    { key = "special",  label = "UI_MinidoracatMiniMap_VCat_Special" },
}

-- 各區的下拉/勾選定義（沿用 settingsApply 管線；engine=true 直寫引擎選項——
-- 原版語意：Isometric/Symbols 由原版 saveSettings 跨場存 WorldMapSettings
-- （ISMiniMap.lua:605-616）、RemoteSymbols 原版即不持久化）
local UNIFIED_LAYER_TICKS = {
    { id = "Players", label = "UI_MinidoracatMiniMap_Players", default = true },
    { id = "RemotePlayers", label = "UI_MinidoracatMiniMap_RemotePlayers", default = true, mpOnly = true },
    { id = "ZombieIntensity", label = "UI_MinidoracatMiniMap_ZombieIntensity", default = false },
    { id = "PlaceNames", label = "UI_MinidoracatMiniMap_PlaceNames", default = true },
    { id = "StreetNames", label = "UI_MinidoracatMiniMap_StreetNames", default = true },
    { id = "Safehouses", label = "UI_MinidoracatMiniMap_Safehouses", default = true },
    { id = "Isometric", label = "IGUI_MapOption_Isometric", engine = true },
    { id = "Symbols", label = "IGUI_MapOption_Symbols", engine = true },
    { id = "RemoteSymbols", label = "IGUI_MapOption_RemoteSymbols", engine = true },
}
local UNIFIED_ZOMBIE_COMBOS = {
    { id = "ZombieDotColor", label = "UI_MinidoracatMiniMap_ZombieDotColor", default = 1,
        items = { "UI_MinidoracatMiniMap_ZDotColor_Orange", "UI_MinidoracatMiniMap_ZDotColor_Yellow",
            "UI_MinidoracatMiniMap_ZDotColor_Purple", "UI_MinidoracatMiniMap_ZDotColor_White",
            "UI_MinidoracatMiniMap_ZDotColor_Red" } },
    { id = "ZombieDotSize", label = "UI_MinidoracatMiniMap_ZombieDotSize", default = 2,
        items = { "UI_MinidoracatMiniMap_ZDotSize_Small", "UI_MinidoracatMiniMap_ZDotSize_Medium",
            "UI_MinidoracatMiniMap_ZDotSize_Large" } },
    { id = "ZombieDotMax", label = "UI_MinidoracatMiniMap_ZombieDotMax", default = 2,
        items = { "UI_MinidoracatMiniMap_ZDotMax_100", "UI_MinidoracatMiniMap_ZDotMax_200",
            "UI_MinidoracatMiniMap_ZDotMax_400", "UI_MinidoracatMiniMap_ZDotMax_800" } },
}
local UNIFIED_ANIMAL_COMBOS = {
    { id = "AnimalIconStyle", label = "UI_MinidoracatMiniMap_AnimalIconStyle", default = 1,
        items = { "UI_MinidoracatMiniMap_AIconStyle_Symbol", "UI_MinidoracatMiniMap_AIconStyle_Item" } },
    { id = "AnimalIconSize", label = "UI_MinidoracatMiniMap_AnimalIconSize", default = 2,
        items = { "UI_MinidoracatMiniMap_ZDotSize_Small", "UI_MinidoracatMiniMap_ZDotSize_Medium",
            "UI_MinidoracatMiniMap_ZDotSize_Large" } },
    { id = "AnimalWildColor", label = "UI_MinidoracatMiniMap_AnimalWildColor", default = 2,
        items = ADOTS_COLOR_ITEMS },
    { id = "AnimalLivestockColor", label = "UI_MinidoracatMiniMap_AnimalLivestockColor", default = 1,
        items = ADOTS_COLOR_ITEMS },
}
local UNIFIED_VEHICLE_COMBOS = {
    { id = "VehicleIconColor", label = "UI_MinidoracatMiniMap_VehicleIconColor", default = 4,
        items = ADOTS_COLOR_ITEMS },
}
local UNIFIED_APPEAR_COMBOS = {
    { id = "MapSize", label = "UI_MinidoracatMiniMap_Size", default = 2,
        items = { "UI_MinidoracatMiniMap_Size_Small", "UI_MinidoracatMiniMap_Size_Medium",
            "UI_MinidoracatMiniMap_Size_Large", "UI_MinidoracatMiniMap_Size_Huge" } },
    { id = "AdornMode", label = "UI_MinidoracatMiniMap_AdornMode", default = 2,
        items = { "UI_MinidoracatMiniMap_AdornMode_Hover", "UI_MinidoracatMiniMap_AdornMode_Always" } },
    { id = "Opacity", label = "UI_MinidoracatMiniMap_Opacity", default = 1,
        items = { "UI_MinidoracatMiniMap_Opacity_Full", "UI_MinidoracatMiniMap_Opacity_Half",
            "UI_MinidoracatMiniMap_Opacity_Faint" } },
}
local UNIFIED_APPEAR_TICKS = {
    { id = "FreeLook", label = "UI_MinidoracatMiniMap_FreeLook", default = true },
    { id = "ClickOpenWorldMap", label = "UI_MinidoracatMiniMap_ClickOpenWorldMap", default = false },
    { id = "TextAnnotations", label = "UI_MinidoracatMiniMap_TextAnnotations", default = false },
    { id = "LockPosition", label = "UI_MinidoracatMiniMap_LockPosition", default = false },
}
-- 世界地圖（M）圖標開關：與小地圖開關獨立（放本 MOD 視窗、不注入原版世界地圖
-- 選項面板避免混淆），風格/顏色/篩選共用小地圖設定（同一 ModOptions 永久記錄）
local UNIFIED_WM_TICKS = {
    { id = "WMZombieDots", label = "UI_MinidoracatMiniMap_WMZombieDots", gate = "AllowZombieDots" },
    { id = "WMAnimalWild", label = "UI_MinidoracatMiniMap_WMAnimalWild", gate = "AllowAnimalDots" },
    { id = "WMAnimalLivestock", label = "UI_MinidoracatMiniMap_WMAnimalLivestock", gate = "AllowAnimalDots" },
    { id = "WMVehicleDots", label = "UI_MinidoracatMiniMap_WMVehicleDots", gate = "AllowVehicleDots" },
}

-- 標題摘要顯示有效狀態，不把已被伺服器閘門壓制的勾選算進去。
-- test:worldmap-effective-tick:start
local function unifiedWorldMapTickOn(t)
    if not getBoolOption(t.id, false) then return false end
    if t.gate and sandboxGate(t.gate, true) == false then return false end
    return t.id ~= "WMAnimalLivestock" or livestockVisibilityMode() ~= 4
end
-- test:worldmap-effective-tick:end
-- 區塊骨架：builder 依 id 分派（見 unifiedRebuild）；gate＝伺服器沙盒閘（停用時標示原因）
local UNIFIED_SECTIONS = {
    { id = "layers", label = "UI_MinidoracatMiniMap_SecLayers" },
    { id = "zombie", label = "UI_MinidoracatMiniMap_SecZombie", gate = "AllowZombieDots" },
    { id = "animals", label = "UI_MinidoracatMiniMap_SecAnimals", gate = "AllowAnimalDots" },
    { id = "vehicles", label = "UI_MinidoracatMiniMap_SecVehicles", gate = "AllowVehicleDots" },
    { id = "worldmap", label = "UI_MinidoracatMiniMap_SecWorldMap" },
    { id = "appearance", label = "UI_MinidoracatMiniMap_SecAppearance" },
}
-- ponytail: 展開狀態 session 記憶即可，跨場記憶（存 ModOptions）是升級路徑
local unifiedExpand = { layers = true }
-- 固定分欄（實測回饋：貪婪平衡會讓區塊隨展開狀態在左右欄跳動，破壞空間記憶）：
-- 左欄＝圖層顯示/世界地圖圖標/外觀與行為，右欄＝殭屍點位/動物圖標/載具圖標
local UNIFIED_LANE = { layers = 1, worldmap = 1, appearance = 1,
    zombie = 2, animals = 2, vehicles = 2 }
local settingsUI -- 單例；獨立頂層視窗，不隨小地圖 Recreate 消失（apply 自行重抓 mm）

-- 地圖包 addon 專屬選項（有註冊才出現）：OnGameBoot＝所有 MOD lua 載入完
-- （地圖包 require=本 MOD，其註冊呼叫已執行）、且早於 MainOptions 建立——
-- 實際順序 OnGameBoot → OnMainMenuEnter → MainOptions:create →
-- addModOptionsPanel 內 PZAPI.ModOptions:load()（MainOptions.lua:409/2822-2823），
-- 晚追加的選項一樣載得到 ini 存檔值。設定視窗 lazy 建立於遊戲內，同樣晚於此。
Events.OnGameBoot.Add(function()
    if #registeredPacks == 0 or not modOptions then return end
    -- ESC 選項頁
    modOptions:addTickBox("MapPackLayers", "UI_MinidoracatMiniMap_MapPackLayers", true,
        "UI_MinidoracatMiniMap_MapPackLayers_tooltip")
    modOptions:addTickBox("MapBounds", "UI_MinidoracatMiniMap_MapBounds", true,
        "UI_MinidoracatMiniMap_MapBounds_tooltip")
    local mbColor = modOptions:addComboBox("MapBoundsColor", "UI_MinidoracatMiniMap_MapBoundsColor")
    mbColor:addItem("UI_MinidoracatMiniMap_MBColor_Green", true) -- 順序須同 MAPB_COLORS
    mbColor:addItem("UI_MinidoracatMiniMap_MBColor_Cyan", false)
    mbColor:addItem("UI_MinidoracatMiniMap_MBColor_Yellow", false)
    mbColor:addItem("UI_MinidoracatMiniMap_MBColor_Purple", false)
    mbColor:addItem("UI_MinidoracatMiniMap_MBColor_White", false)
    -- 統一視窗同步加項：圖層區兩顆勾選＋外觀區框線顏色下拉
    table.insert(UNIFIED_LAYER_TICKS, { id = "MapPackLayers",
        label = "UI_MinidoracatMiniMap_MapPackLayers", default = true })
    table.insert(UNIFIED_LAYER_TICKS, { id = "MapBounds",
        label = "UI_MinidoracatMiniMap_MapBounds", default = true })
    table.insert(UNIFIED_APPEAR_COMBOS, { id = "MapBoundsColor",
        label = "UI_MinidoracatMiniMap_MapBoundsColor", default = 1,
        items = { "UI_MinidoracatMiniMap_MBColor_Green", "UI_MinidoracatMiniMap_MBColor_Cyan",
            "UI_MinidoracatMiniMap_MBColor_Yellow", "UI_MinidoracatMiniMap_MBColor_Purple",
            "UI_MinidoracatMiniMap_MBColor_White" } })
end)

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

-- CSV 集合（停用鍵）：gmatch 用例 ISCharacterScreen.lua（Kahlua 支援）。
-- 空集合以 "-" sentinel 儲存：PZAPI 存讀管線會把空 textentry 讀成 nil 再存成
-- 字串 "nil"（load 用 luautils.split 丟尾端空欄，ModOptions.lua:304），
-- 空字串走一輪就變髒——讀取端把 "-"/"nil" 一律視為空
local function unifiedCsvSet(raw)
    local set = {}
    for w in string.gmatch(tostring(raw or ""), "[^,]+") do
        if w ~= "-" and w ~= "nil" then set[w] = true end
    end
    return set
end

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

-- 篩選寫入：單鍵切換／全選全不選；序列化依定義序（ini diff 穩定）。
-- 不呼叫 apply()——取樣端下輪（≤0.5s）經 cache key 察覺變更
local function unifiedSetFilter(optId, uiDefs, key, enabled)
    if not modOptions then return end
    local opt = modOptions:getOption(optId)
    if not opt then return end
    local dis = unifiedCsvSet(opt:getValue())
    if enabled then dis[key] = nil else dis[key] = true end
    local parts = {}
    for i = 1, #uiDefs do
        if dis[uiDefs[i].key] then parts[#parts + 1] = uiDefs[i].key end
    end
    -- 空集合寫 "-"（見 unifiedCsvSet 註解的 PZAPI 空字串髒化問題）
    opt:setValue(#parts > 0 and table.concat(parts, ",") or "-")
    PZAPI.ModOptions:save()
end
local function unifiedSetAllFilter(optId, uiDefs, enabled)
    if not modOptions then return end
    local opt = modOptions:getOption(optId)
    if not opt then return end
    if enabled then
        opt:setValue("-") -- 空集合 sentinel（見 unifiedCsvSet 註解）
    else
        local parts = {}
        for i = 1, #uiDefs do parts[#parts + 1] = uiDefs[i].key end
        opt:setValue(table.concat(parts, ","))
    end
    PZAPI.ModOptions:save()
end

-- 引擎選項直讀直寫（等軸測/符號/遠端符號）：無小地圖時讀 false、寫 no-op。
-- pn＝視窗擁有者（分割畫面 P2+ 開的視窗不能讀寫到 P1 的小地圖）
local function unifiedEngineGet(name, pn)
    pn = pn or 0
    local mm = getSpecificPlayer(pn) and getPlayerMiniMap(pn)
    local api = mm and mm.inner and mm.inner.mapAPI
    return api ~= nil and api:getBoolean(name) or false
end
local function unifiedEngineSet(name, v, pn)
    pn = pn or 0
    local mm = getSpecificPlayer(pn) and getPlayerMiniMap(pn)
    local api = mm and mm.inner and mm.inner.mapAPI
    if api then api:setBoolean(name, v) end
end

-- 區塊標題的現況摘要（panel:render 每幀現算——展開區的勾選改動、甚至 ESC
-- 選項頁改動都即時反映；≤6 區、純選項記憶體讀，每幀成本可忽略。實測回饋：
-- 舊版重建時算一次存字串，勾選後要再點收合/展開才更新）
local function unifiedHeaderSummary(sec, pn)
    local function onOff(v)
        return getText(v and "UI_MinidoracatMiniMap_On" or "UI_MinidoracatMiniMap_Off")
    end
    if sec.id == "layers" then
        local n, on = 0, 0
        for i = 1, #UNIFIED_LAYER_TICKS do
            local t = UNIFIED_LAYER_TICKS[i]
            if not (t.mpOnly and not isClient()) then
                n = n + 1
                local v = t.engine and unifiedEngineGet(t.id, pn) or (not t.engine and getBoolOption(t.id, t.default))
                if v then on = on + 1 end
            end
        end
        return on .. "/" .. n
    elseif sec.id == "zombie" then
        return onOff(getBoolOption("ZombieDots", false)
            and sandboxGate("AllowZombieDots", true) ~= false)
    elseif sec.id == "animals" then
        local allowed = sandboxGate("AllowAnimalDots", true) ~= false
        local livestock = getBoolOption("AnimalLivestock", false) and livestockVisibilityMode() ~= 4
        return onOff(allowed and (getBoolOption("AnimalWild", false) or livestock))
    elseif sec.id == "vehicles" then
        return onOff(getBoolOption("VehicleDots", false)
            and sandboxGate("AllowVehicleDots", true) ~= false)
    elseif sec.id == "worldmap" then
        -- 對等勾選清單＝計數摘要（同 layers；開/關會被誤讀成母開關——實測回饋）
        local on = 0
        for i = 1, #UNIFIED_WM_TICKS do
            local t = UNIFIED_WM_TICKS[i]
            if unifiedWorldMapTickOn(t) then on = on + 1 end
        end
        return on .. "/" .. #UNIFIED_WM_TICKS
    end
    return nil
end

-- 全清重建：收合/展開/全選類操作直接重建所有列（值變動一律讀現值，免同步邏輯）。
-- v3 版面：雙欄 lane（區塊貪婪放進較短欄，全展開高度約砍半）＋內容捲動容器
-- （高度夾 viewport，永不超出螢幕——先前全展開高於螢幕、底部被切＝疊字/消失根因）
local function unifiedRebuild(win)
    local panel = win._content
    for i = 1, #win._rows do panel:removeChild(win._rows[i]) end
    win._rows = {}
    win._headers = {}
    win._icons = {}
    local pn = win._playerNum or 0 -- 視窗擁有者（分割畫面 P2+ 不能讀寫到 P1）
    local livestockMode = livestockVisibilityMode()
    win._minidoracatLivestockMode = livestockMode
    local tm = getTextManager()
    local fontH = tm:getFontHeight(UIFont.Small)
    local rowH = fontH + 8
    local pad = 10
    -- 各語系標籤實測寬度決定 lane 寬與欄數：CJK/EN 字長差異大，固定欄寬會
    -- 右緣裁字、兩欄疊字（實測回饋）。MeasureStringX 用例 ISMiniMap.lua:31
    local function tw(t) return tm:MeasureStringX(UIFont.Small, t) end
    local TICK_W = fontH + 10 -- tickbox 方框＋間距的寬度預算（過估安全）
    local max2 = 0 -- 2 欄群組（圖層/外觀勾選/動物母開關/載具類別）最長標籤
    for i = 1, #UNIFIED_LAYER_TICKS do
        local t = UNIFIED_LAYER_TICKS[i]
        if not (t.mpOnly and not isClient()) then
            max2 = math.max(max2, tw(getTextOrNull(t.label) or t.id))
        end
    end
    for i = 1, #UNIFIED_APPEAR_TICKS do
        max2 = math.max(max2, tw(getText(UNIFIED_APPEAR_TICKS[i].label)))
    end
    max2 = math.max(max2, tw(getText("UI_MinidoracatMiniMap_AnimalWild")),
        tw(getText("UI_MinidoracatMiniMap_AnimalLivestock")),
        tw(getText("UI_MinidoracatMiniMap_ZombieDots")),
        tw(getText("UI_MinidoracatMiniMap_VehicleDots")))
    for i = 1, #ADOTS_VEHCAT_UI do
        max2 = math.max(max2, tw(getText(ADOTS_VEHCAT_UI[i].label)))
    end
    for i = 1, #UNIFIED_WM_TICKS do
        max2 = math.max(max2, tw(getText(UNIFIED_WM_TICKS[i].label)))
    end
    local need2 = max2 + TICK_W + 8       -- 2 欄群組單欄所需
    local max3 = 0                        -- 物種格（圖示＋勾選＋名）
    for i = 1, #ADOTS_SPECIES_UI do
        max3 = math.max(max3, tw(getText(ADOTS_SPECIES_UI[i].label)))
    end
    local need3 = max3 + TICK_W + fontH + 10
    local comboLabelW = 0                 -- combo 列標籤欄
    local comboGroups = { UNIFIED_ZOMBIE_COMBOS, UNIFIED_ANIMAL_COMBOS,
        UNIFIED_VEHICLE_COMBOS, UNIFIED_APPEAR_COMBOS }
    for g = 1, #comboGroups do
        for i = 1, #comboGroups[g] do
            comboLabelW = math.max(comboLabelW, tw(getText(comboGroups[g][i].label)))
        end
    end
    -- lane 寬＝滿足 lane 內最寬需求（2 欄雙倍/3 欄三倍/combo 標籤＋最小下拉 130），
    -- 夾上限後降欄數（2→1、3→2→1）——寧可長高（有捲動兜底），不裁字
    local statusW = tw(getText("UI_MinidoracatMiniMap_LivestockHiddenBySandbox")) + 8
    local laneW = math.max(300, need2 * 2 + 12, need3 * 3 + 12,
        comboLabelW + 130 + 12, statusW)
    if laneW > 420 then laneW = 420 end
    local cols2 = (need2 * 2 + 12 <= laneW) and 2 or 1
    local cols3 = 3
    if need3 * 3 + 12 > laneW then
        cols3 = (need3 * 2 + 12 <= laneW) and 2 or 1
    end
    local colW2 = math.floor((laneW - 6) / cols2)
    local colW3 = math.floor((laneW - 6) / cols3)
    local W = pad * 2 + laneW * 2 + 12 + 14 -- 雙 lane＋中縫＋右側捲軸預留
    win:setWidth(W)
    panel:setWidth(W)
    -- 標題列右側鈕補位：釘選/收合鈕以「建立當下」寬度定位（ISCollapsableWindow.lua:72/83，
    -- anchorRight 對 Lua setWidth 不生效——實測釘選卡在舊寬度處），改寬後手動跟上
    local tbBtn = win.pinButton or win.collapseButton
    local tbH = tbBtn and tbBtn.height or 16
    if win.pinButton then win.pinButton:setX(W - 1 - tbH) end
    if win.collapseButton then win.collapseButton:setX(W - 1 - tbH) end
    -- 雙欄游標：curX/curY＝目前 lane 的基準 x 與游標 y（helpers 讀寫 curY）；
    -- 座標皆為 panel 內容座標（捲動由 panel 處理）
    local laneX = { pad, pad + laneW + 12 }
    local laneY = { 0, 0 }
    local curX, curY = laneX[1], 0

    local function add(el)
        panel:addChild(el)
        win._rows[#win._rows + 1] = el
        return el
    end
    local function onModTick(target, index, selected, e)
        settingsApply(e, selected)
        -- PlaceNames 開啟會連動強制 Symbols=true（applyToggleOptions 的耦合）：
        -- 重建讓「符號」勾選框立即反映引擎現值，不留 UI/引擎分裂
        if e.id == "PlaceNames" then unifiedRebuild(win) end
    end
    local function onEngineTick(target, index, selected, e) unifiedEngineSet(e.id, selected, pn) end
    -- ISTickBox:new 用法同原設定視窗建法（ISTickBox.lua:282）；單框單選項
    local function addTick(x, yy, w, labelText, checked, cb, arg)
        local t = ISTickBox:new(x, yy, w, fontH + 4, "", win, cb, arg)
        t:initialise()
        t:addOption(labelText)
        t:setSelected(1, checked and true or false)
        return add(t)
    end
    -- 下拉列（ISComboBox 建法/回呼同原視窗：ISComboBox.lua:586/253）；
    -- 標籤欄寬＝全部 combo 標籤實測最寬（各語系自適應），佔滿目前 lane
    local function addComboRow(entry)
        add(ISLabel:new(curX, curY + 3, fontH, getText(entry.label), 1, 1, 1, 1, UIFont.Small, true))
        local combo = ISComboBox:new(curX + comboLabelW + 8, curY, laneW - comboLabelW - 8, fontH + 6, win,
            function(target, box, e) settingsApply(e, box.selected) end, entry)
        combo:initialise()
        for j = 1, #entry.items do combo:addOption(getText(entry.items[j])) end
        combo.selected = getComboIndex(entry.id, entry.default)
        add(combo)
        curY = curY + rowH
    end
    local function addBtn(x, yy, w, labelText, fn, tooltip)
        local b = ISButton:new(x, yy, w, fontH + 4, labelText, win, fn)
        b:initialise()
        b.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
        if tooltip then b.tooltip = tooltip end
        return add(b)
    end

    -- 一鍵全展開/全收合（實測回饋）：頂列橫跨兩 lane
    local halfTop = math.floor((W - pad * 2 - 4) / 2)
    addBtn(pad, 0, halfTop, getText("UI_MinidoracatMiniMap_ExpandAll"), function()
        for i = 1, #UNIFIED_SECTIONS do unifiedExpand[UNIFIED_SECTIONS[i].id] = true end
        unifiedRebuild(win)
    end)
    addBtn(pad + halfTop + 4, 0, halfTop, getText("UI_MinidoracatMiniMap_CollapseAll"), function()
        for i = 1, #UNIFIED_SECTIONS do unifiedExpand[UNIFIED_SECTIONS[i].id] = nil end
        unifiedRebuild(win)
    end)
    laneY[1] = rowH + 4
    laneY[2] = rowH + 4

    for s = 1, #UNIFIED_SECTIONS do
        local sec = UNIFIED_SECTIONS[s]
        local expanded = unifiedExpand[sec.id] and true or false
        local cur = UNIFIED_LANE[sec.id] or 1 -- 固定分欄，位置不隨展開狀態變動
        curX = laneX[cur]
        curY = laneY[cur]
        -- 標題列＝空字 ISButton（點擊/hover 底），文字由捲動面板 render 畫
        -- （ISButton 標題強制置中，左對齊＋右側摘要只能自畫）
        local hdr = ISButton:new(curX - 4, curY, laneW + 8, fontH + 6, "", win,
            function(target, btn)
                unifiedExpand[btn._minidoracatSec] = not unifiedExpand[btn._minidoracatSec]
                unifiedRebuild(win)
            end)
        hdr._minidoracatSec = sec.id
        hdr:initialise()
        hdr.borderColor = { r = 0.35, g = 0.35, b = 0.35, a = 1 }
        hdr.backgroundColor = { r = 1, g = 1, b = 1, a = 0.06 }
        add(hdr)
        win._headers[#win._headers + 1] = {
            x = curX + 2, y = curY + 3, rx = curX + laneW - 2,
            text = (expanded and "- " or "+ ") .. getText(sec.label),
            sec = sec, -- 摘要由 panel:render 每幀現算（見 unifiedHeaderSummary）
        }
        curY = curY + fontH + 10
        if expanded then
            if sec.gate and sandboxGate(sec.gate, true) == false then
                add(ISLabel:new(curX + 4, curY, fontH, getText("UI_MinidoracatMiniMap_ServerDisabled"),
                    0.95, 0.55, 0.25, 1, UIFont.Small, true))
                curY = curY + rowH
            end
            if sec.id == "layers" then
                local col = 0
                for i = 1, #UNIFIED_LAYER_TICKS do
                    local t = UNIFIED_LAYER_TICKS[i]
                    if not (t.mpOnly and not isClient()) then
                        local checked = t.engine and unifiedEngineGet(t.id, pn)
                            or (not t.engine and getBoolOption(t.id, t.default))
                        addTick(curX + 4 + col * colW2, curY, colW2 - 8,
                            getTextOrNull(t.label) or t.id, checked,
                            t.engine and onEngineTick or onModTick, t)
                        col = col + 1
                        if col == cols2 then col = 0; curY = curY + rowH end
                    end
                end
                if col ~= 0 then curY = curY + rowH end
            elseif sec.id == "zombie" then
                addTick(curX + 4, curY, laneW - 6, getText("UI_MinidoracatMiniMap_ZombieDots"),
                    getBoolOption("ZombieDots", false), onModTick, { id = "ZombieDots" })
                curY = curY + rowH
                for i = 1, #UNIFIED_ZOMBIE_COMBOS do addComboRow(UNIFIED_ZOMBIE_COMBOS[i]) end
            elseif sec.id == "animals" then
                local masters = {
                    { id = "AnimalWild", label = "UI_MinidoracatMiniMap_AnimalWild" },
                    { id = "AnimalLivestock", label = "UI_MinidoracatMiniMap_AnimalLivestock" },
                }
                local col = 0
                for i = 1, #masters do
                    addTick(curX + 4 + col * colW2, curY, colW2 - 8, getText(masters[i].label),
                        getBoolOption(masters[i].id, false), onModTick, { id = masters[i].id })
                    col = col + 1
                    if col == cols2 then col = 0; curY = curY + rowH end
                end
                if col ~= 0 then curY = curY + rowH end
                if livestockMode == 4 then
                    add(ISLabel:new(curX + 4, curY, fontH,
                        getText("UI_MinidoracatMiniMap_LivestockHiddenBySandbox"),
                        0.95, 0.55, 0.25, 1, UIFont.Small, true))
                    curY = curY + rowH
                end
                -- 物種網格（欄數自適應）：列首小圖（捲動面板 render 畫）＋勾選（勾＝顯示）
                local disOpt = modOptions and modOptions:getOption("AnimalSpeciesFilter")
                local dis = unifiedCsvSet(disOpt and disOpt:getValue() or "")
                for i = 1, #ADOTS_SPECIES_UI do
                    local def = ADOTS_SPECIES_UI[i]
                    local cx = curX + 4 + ((i - 1) % cols3) * colW3
                    local cy = curY + math.floor((i - 1) / cols3) * rowH
                    local art = ADOTS_ART and ADOTS_ART[def.groups[1]]
                    win._icons[#win._icons + 1] = { name = art and art.sym, x = cx, y = cy, size = fontH + 2 }
                    addTick(cx + fontH + 5, cy, colW3 - fontH - 6, getText(def.label), not dis[def.key],
                        function(target, index, selected, e)
                            unifiedSetFilter("AnimalSpeciesFilter", ADOTS_SPECIES_UI, e.key, selected)
                        end, def)
                end
                curY = curY + math.ceil(#ADOTS_SPECIES_UI / cols3) * rowH + 2
                local halfW = math.floor((laneW - 10) / 2)
                addBtn(curX + 4, curY, halfW, getText("UI_MinidoracatMiniMap_SelectAll"), function()
                    unifiedSetAllFilter("AnimalSpeciesFilter", ADOTS_SPECIES_UI, true)
                    unifiedRebuild(win)
                end)
                addBtn(curX + 4 + halfW + 4, curY, halfW, getText("UI_MinidoracatMiniMap_SelectNone"), function()
                    unifiedSetAllFilter("AnimalSpeciesFilter", ADOTS_SPECIES_UI, false)
                    unifiedRebuild(win)
                end)
                curY = curY + rowH
                for i = 1, #UNIFIED_ANIMAL_COMBOS do addComboRow(UNIFIED_ANIMAL_COMBOS[i]) end
            elseif sec.id == "vehicles" then
                addTick(curX + 4, curY, laneW - 6, getText("UI_MinidoracatMiniMap_VehicleDots"),
                    getBoolOption("VehicleDots", false), onModTick, { id = "VehicleDots" })
                curY = curY + rowH
                local disOpt = modOptions and modOptions:getOption("VehicleCategoryFilter")
                local dis = unifiedCsvSet(disOpt and disOpt:getValue() or "")
                for i = 1, #ADOTS_VEHCAT_UI do
                    local def = ADOTS_VEHCAT_UI[i]
                    local cx = curX + 4 + ((i - 1) % cols2) * colW2
                    local cy = curY + math.floor((i - 1) / cols2) * rowH
                    addTick(cx, cy, colW2 - 8, getText(def.label), not dis[def.key],
                        function(target, index, selected, e)
                            unifiedSetFilter("VehicleCategoryFilter", ADOTS_VEHCAT_UI, e.key, selected)
                        end, def)
                end
                curY = curY + math.ceil(#ADOTS_VEHCAT_UI / cols2) * rowH
                for i = 1, #UNIFIED_VEHICLE_COMBOS do addComboRow(UNIFIED_VEHICLE_COMBOS[i]) end
            elseif sec.id == "worldmap" then
                local col = 0
                for i = 1, #UNIFIED_WM_TICKS do
                    local t = UNIFIED_WM_TICKS[i]
                    addTick(curX + 4 + col * colW2, curY, colW2 - 8, getText(t.label),
                        getBoolOption(t.id, false), onModTick, { id = t.id })
                    col = col + 1
                    if col == cols2 then col = 0; curY = curY + rowH end
                end
                if col ~= 0 then curY = curY + rowH end
                if livestockMode == 4 then
                    add(ISLabel:new(curX + 4, curY, fontH,
                        getText("UI_MinidoracatMiniMap_LivestockHiddenBySandbox"),
                        0.95, 0.55, 0.25, 1, UIFont.Small, true))
                    curY = curY + rowH
                end
                add(ISLabel:new(curX + 4, curY, fontH, getText("UI_MinidoracatMiniMap_WMShared"),
                    0.62, 0.62, 0.62, 1, UIFont.Small, true))
                curY = curY + rowH
            elseif sec.id == "appearance" then
                for i = 1, #UNIFIED_APPEAR_COMBOS do addComboRow(UNIFIED_APPEAR_COMBOS[i]) end
                local col = 0
                for i = 1, #UNIFIED_APPEAR_TICKS do
                    local t = UNIFIED_APPEAR_TICKS[i]
                    addTick(curX + 4 + col * colW2, curY, colW2 - 8, getText(t.label),
                        getBoolOption(t.id, t.default), onModTick, t)
                    col = col + 1
                    if col == cols2 then col = 0; curY = curY + rowH end
                end
                if col ~= 0 then curY = curY + rowH end
                -- 恢復預設尺寸：清 CustomSize 回下拉正方形（apply→save 順序同 settingsApply）
                addBtn(curX + 4, curY + 2, laneW - 6, getText("UI_MinidoracatMiniMap_ResetSize"),
                    function()
                        if not modOptions then return end
                        local opt = modOptions:getOption("CustomSize")
                        if not opt then return end
                        opt:setValue("")
                        if modOptions.apply then modOptions:apply() end
                        PZAPI.ModOptions:save()
                    end, getText("UI_MinidoracatMiniMap_ResetSize_tooltip"))
                curY = curY + rowH + 4
            end
        end
        laneY[cur] = curY + 6
    end
    -- 內容高＝較長 lane；面板高夾玩家 viewport，超出開捲動
    -- （setScrollHeight/getScrollHeight＝ISUIElement 內建捲動 API）
    local contentH = math.max(laneY[1], laneY[2]) + 4
    local vh = getPlayerScreenHeight(pn)
    local maxPanelH = math.floor(vh * 0.9) - win:titleBarHeight() - 8
    local panelH = math.min(contentH, maxPanelH)
    panel:setHeight(panelH)
    panel:setScrollHeight(contentH)
    -- 內容縮短時把捲動位置夾回有效範圍（否則留白/內容跑出上緣）
    local maxScroll = math.max(0, contentH - panelH)
    local ys = panel:getYScroll()
    if ys < -maxScroll then panel:setYScroll(-maxScroll) end
    if ys > 0 then panel:setYScroll(0) end
    if panel.vscroll then
        panel.vscroll:setHeight(panelH)
        panel.vscroll:setX(W - 12)
    end
    win:setHeight(win:titleBarHeight() + panelH + 4)
    -- 重建會改變寬高：視窗開著時重新夾回擁有者 viewport（底部上推、右緣不溢出）
    if win:isVisible() then
        local sx, sy = getPlayerScreenLeft(pn), getPlayerScreenTop(pn)
        local sw, sh = getPlayerScreenWidth(pn), getPlayerScreenHeight(pn)
        local x, wy = win:getX(), win:getY()
        if x + win.width > sx + sw then x = sx + sw - win.width end
        if x < sx then x = sx end
        if wy + win.height > sy + sh then wy = sy + sh - win.height end
        if wy < sy then wy = sy end
        win:setX(x)
        win:setY(wy)
    end
end

local function buildSettingsWindow()
    local win = ISCollapsableWindow:new(0, 0, 700, 200) -- 寬高由 unifiedRebuild 重算
    win.resizable = false -- 同圖層面板做法（ISMiniMap.lua:187）
    win:setTitle(getText("UI_MinidoracatMiniMap_Options")) -- setTitle＝ISCollapsableWindow.lua:18-20
    win:initialise()
    win:addToUIManager()
    win:setVisible(false)
    win._rows = {}
    win._headers = {}
    win._icons = {}
    win._playerNum = 0
    -- 內容捲動容器：所有列掛在這層；內容高超過 viewport 出捲軸。
    -- setScrollChildren/addScrollBars/setScrollHeight＝ISUIElement 內建；
    -- stencil 於 prerender 設、render 尾清＝原版滾動清單慣例（ISScrollingListBox 同構）
    local panel = ISPanel:new(0, win:titleBarHeight(), win.width, 100)
    panel:initialise()
    panel.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    panel.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    panel:setScrollChildren(true)
    panel:addScrollBars()
    function panel:onMouseWheel(del)
        local maxScroll = math.max(0, (self:getScrollHeight() or 0) - self.height)
        local ys = self:getYScroll() - del * 48
        if ys < -maxScroll then ys = -maxScroll end
        if ys > 0 then ys = 0 end
        self:setYScroll(ys)
        return true
    end
    function panel:prerender()
        self:setStencilRect(0, 0, self.width, self.height)
        ISPanel.prerender(self)
    end
    -- 自畫層：區塊標題（左對齊＋右側摘要）與物種小圖（drawText＝ISUIElement.lua:1293）。
    -- 畫在 panel 的 render＝子元件之後（文字疊在 header 鈕 hover 底色之上——
    -- 掛 prerender 會被 hover 蓋掉，實測回饋）；且在 stencil 內＝跟內容一起裁切，
    -- 直繪座標手動加 getYScroll 跟隨捲動；視窗收合時 panel 不繪＝無穿透
    function panel:render()
        ISPanel.render(self)
        local w = self.parent
        local ys = self:getYScroll()
        local tm = getTextManager()
        for i = 1, #w._headers do
            local h = w._headers[i]
            self:drawText(h.text, h.x, h.y + ys, 0.92, 0.72, 0.25, 1, UIFont.Small)
            local right = h.sec and unifiedHeaderSummary(h.sec, w._playerNum or 0)
            if right then
                local tww = tm:MeasureStringX(UIFont.Small, right)
                self:drawText(right, h.rx - tww, h.y + ys, 0.62, 0.62, 0.62, 1, UIFont.Small)
            end
        end
        for i = 1, #w._icons do
            local ic = w._icons[i]
            local tex = ic.name and adotsTexture and adotsTexture(ic.name)
            if tex then
                self:drawTextureScaled(tex, ic.x, ic.y + 1 + ys, ic.size, ic.size, 1, 0.92, 0.92, 0.92)
            end
        end
        self:clearStencilRect()
    end
    win:addChild(panel)
    win._content = panel
    unifiedRebuild(win)
    -- 視窗保持開啟時也追蹤伺服器 live sandbox 更新；只在有效模式改變時重建，
    -- 平常 prerender 不增加配置或子元件 churn。
    local originalSettingsPrerender = win.prerender
    function win:prerender()
        if self._minidoracatLivestockMode ~= livestockVisibilityMode() then
            unifiedRebuild(self)
        end
        originalSettingsPrerender(self)
    end
    return win
end

toggleSettingsWindow = function(outer)
    if not settingsUI then settingsUI = buildSettingsWindow() end
    local pn = outer.playerNum or 0
    if settingsUI:isVisible() then
        -- 同一位玩家再按＝關閉；不同玩家按（分割畫面：世界地圖單例／各自小地圖
        -- 都會轉呼此處）＝改掛新擁有者重建重定位，而不是把前一位的視窗關掉——
        -- 否則 P2 第一按只會關 P1 的窗，或直接沿用 P1 身分讀寫引擎選項
        if settingsUI._playerNum == pn then
            settingsUI:setVisible(false)
            return
        end
    end
    settingsUI._playerNum = pn -- 視窗擁有者（分割畫面各自讀寫自己的小地圖）
    unifiedRebuild(settingsUI) -- 開窗即重建＝同步現值（可能在 ESC 選項頁被改過）
    -- 靠小地圖左側、夾進該玩家 viewport（取法同圖層面板定位）
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

-- 按鈕列重排：6 顆（M - + C ⚙ X）以動態間距塞進 inner 寬度
-- （原版置中排版只按 5 顆算，ISMiniMap.lua:417；最小寬 180 時縮間距到 2px 仍可容納）
local function relayoutBottomButtons(mm)
    local order = { mm.button1, mm.button2, mm.button3, mm._minidoracatCenterBtn,
        mm.button4, mm.button6 }
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
    -- 「=」圖層面板鈕已退役：引擎原生三項移入統一視窗「圖層顯示」區。
    -- 原版面板機制（getVisibleOptions/onTickBox wrap 等）保留不拆——
    -- 面板已無入口，但第三方 MOD 若開啟它，注入與回寫仍正確
    mm.button4.tooltip = getText("UI_MinidoracatMiniMap_BtnSettings")
    -- 原版按鈕補 tooltip（M/-/+/X 原版無滑鼠提示；tooltip 欄位同上）
    if mm.button1 then mm.button1.tooltip = getText("UI_MinidoracatMiniMap_BtnWorldMap") end
    if mm.button2 then mm.button2.tooltip = getText("UI_MinidoracatMiniMap_BtnZoomOut") end
    if mm.button3 then mm.button3.tooltip = getText("UI_MinidoracatMiniMap_BtnZoomIn") end
    if mm.button6 then mm.button6.tooltip = getText("UI_MinidoracatMiniMap_BtnClose") end
    relayoutBottomButtons(mm)
    -- 6 顆按鈕的最小可容寬度回寫尺寸下限：UI 字型放大時 BUTTON_HGT 跟著變大，
    -- 固定 180 會塞不下（6 鈕＋5×2px 間距＋外框），動態墊高避免縮到溢出
    local minW = 6 * ref.width + 5 * 2 + (mm.borderSize or 2) * 2 + 4
    if minW > RESIZE_MIN then RESIZE_MIN = minW end
    -- ponytail: 新鈕未登記手把導航列（原版 insertNewLineOfButtons 於 createChildren
    -- 一次性登記，事後補列會亂序）；手把用戶走 ESC 選項頁（PZAPI ModOptions
    -- 已列全部開關），需要時再補登記
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
-- 世界地圖（M 鍵）亦可畫（WM* 獨立開關，見 drawZombieDotsOn 與 ISWorldMap
-- prerender wrap）——客戶端只知道已載入個體，拉遠不會鋪滿全圖。
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

-- 小地圖可視範圍的世界座標外接框：視窗四角 uiToWorld（2 參數版用例
-- ISMiniMap.lua:234-235）取 min/max——等軸測下視窗是世界座標裡的旋轉四邊形，
-- 外接框是超集，夠用；±2 格邊距容住取樣間隔內的移動。殭屍與動物取樣共用。
local function visibleWorldAABB(inner)
    local mapAPI = inner.mapAPI
    local w, h = inner.width, inner.height
    local wx1, wy1 = mapAPI:uiToWorldX(0, 0), mapAPI:uiToWorldY(0, 0)
    local wx2, wy2 = mapAPI:uiToWorldX(w, 0), mapAPI:uiToWorldY(w, 0)
    local wx3, wy3 = mapAPI:uiToWorldX(w, h), mapAPI:uiToWorldY(w, h)
    local wx4, wy4 = mapAPI:uiToWorldX(0, h), mapAPI:uiToWorldY(0, h)
    return math.min(wx1, wx2, wx3, wx4) - 2, math.max(wx1, wx2, wx3, wx4) + 2,
        math.min(wy1, wy2, wy3, wy4) - 2, math.max(wy1, wy2, wy3, wy4) + 2
end

-- test:zombie-sampling:start
local function sampleZombieDots(inner)
    local pn = inner.playerNum or 0
    local st = zdotsStateFor(inner)
    local dist = sandboxDist("ZombieDotDistance")
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
            log("殭屍取樣失敗（本表面僅記錄一次）: " .. tostring(err))
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
    if sandboxGate("AllowZombieDots", true) == false then return end -- 伺服器沙盒禁用
    local st = sampleZombieDots(el)
    local c = ZDOTS_COLORS[getComboIndex("ZombieDotColor", 1)] or ZDOTS_COLORS[1]
    local size = ZDOTS_SIZES[getComboIndex("ZombieDotSize", 2)] or 3
    local mapAPI = el.mapAPI
    for i = 1, st.count do
        local d = st.dots[i]
        -- 世界→UI 座標：worldToUIX/Y＝UIWorldMapV1.java:298/311
        local ux = mapAPI:worldToUIX(d.x, d.y)
        local uy = mapAPI:worldToUIY(d.x, d.y)
        -- 手動裁到視窗內（Lua drawRect 不吃元件裁切）；含描邊起繪於 ux-2。
        -- drawRect＝ISUIElement.lua:1191（引數 x,y,w,h,a,r,g,b）
        if ux >= 2 and uy >= 2 and ux <= el.width - size and uy <= el.height - size then
            el:drawRect(ux - 2, uy - 2, size + 2, size + 2, ZDOTS_EDGE_A, 0, 0, 0)
            el:drawRect(ux - 1, uy - 1, size, size, ZDOTS_A, c[1], c[2], c[3])
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
-- 尺寸分風格兩表：物品彩圖細節多、同尺寸下比單色 glyph 糊（實測回饋），整表調大
local ADOTS_SIZES_SYM = { 12, 16, 20 }  -- 符號風格 小/中（預設）/大（px）
local ADOTS_SIZES_ITEM = { 16, 20, 26 } -- 物品彩圖風格 小/中（預設）/大（px）
-- 圖標染色盤：索引對應 ADOTS_COLOR_ITEMS（選項註冊區）順序，兩表必須同步。
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

-- 物種 → 圖標素材。活鹿無物品圖（不可入包的動物只有屍體圖），物品風格用鹿屍圖；
-- 未知物種（其他 MOD 動物）→ 腳印備援。（local 前置宣告於統一視窗一節——視窗畫物種小圖）
ADOTS_ART = {
    chicken = { sym = "media/ui/LootableMaps/map_chicken.png", item = "Item_Chicken_HenBrown" },
    cow     = { sym = "media/ui/LootableMaps/map_cow.png",     item = "Item_CowBrown_Calf" },
    pig     = { sym = "media/ui/LootableMaps/map_pig.png",     item = "Item_PigWhite_Piglet" },
    sheep   = { sym = "media/ui/LootableMaps/map_sheep.png",   item = "Item_SheepSuffolk_Lamb" },
    deer    = { sym = "media/ui/LootableMaps/map_deer.png",    item = "Item_DeerFemale_Dead" },
    rabbit  = { sym = "media/ui/LootableMaps/map_rabbit.png",  item = "Item_Rabbit" },
    raccoon = { sym = "media/ui/LootableMaps/map_raccoon.png", item = "Item_Raccoon" },
    rat     = { sym = "media/ui/LootableMaps/map_rodent.png",  item = "Item_Rat" },
    mouse   = { sym = "media/ui/LootableMaps/map_rodent.png",  item = "Item_Mouse" },
    turkey  = { sym = "media/ui/LootableMaps/map_turkey.png",  item = "Item_TurkeyHen" },
}
local ADOTS_FALLBACK_SYM = "media/ui/LootableMaps/map_pawprint.png"

-- 第三方相容包可為既有 IsoAnimal group 加入物種篩選項，並選擇提供自己的符號／彩圖。
-- 本 API 只登記 UI/篩選資料與素材路徑：不接收 callback、不讀第三方私有狀態，也不接管其標記。
-- 同一 group 僅能由一個定義擁有；完全相同的重複註冊視為冪等成功。
-- test:animal-group-registry:start
function MinidoracatMiniMapAPI.registerAnimalGroup(ownerModId, group, labelKey, symbolPath, itemPath)
    local valid = type(ownerModId) == "string" and string.find(ownerModId, "%S") ~= nil
        and type(group) == "string" and string.find(group, "%S") ~= nil
        and type(labelKey) == "string" and string.find(labelKey, "%S") ~= nil
        and (symbolPath == nil or (type(symbolPath) == "string" and string.find(symbolPath, "%S") ~= nil))
        and (itemPath == nil or (type(itemPath) == "string" and string.find(itemPath, "%S") ~= nil))
        and group ~= "-" and group ~= "nil"
        and string.find(group, ",", 1, true) == nil
    if not valid then
        print("[MinidoracatMiniMap] registerAnimalGroup 參數錯誤"
            .. "（需 ownerModId, group, labelKey；素材路徑可省略但不可為空；group 不可含逗號或使用保留值）")
        return false
    end

    local expectedSymbol = symbolPath or ADOTS_FALLBACK_SYM

    for i = 1, #ADOTS_SPECIES_UI do
        local def = ADOTS_SPECIES_UI[i]
        for j = 1, #def.groups do
            if def.groups[j] == group then
                local art = ADOTS_ART[group]
                if def.owner == ownerModId and def.key == group and def.label == labelKey
                    and art and art.sym == expectedSymbol and art.item == itemPath then
                    return true
                end
                print("[MinidoracatMiniMap] registerAnimalGroup: group '" .. group
                    .. "' 已被其他物種定義使用（來源 " .. ownerModId .. "）")
                return false
            end
        end
    end

    table.insert(ADOTS_SPECIES_UI, {
        key = group,
        label = labelKey,
        groups = { group },
        owner = ownerModId,
    })
    ADOTS_ART[group] = { sym = expectedSymbol, item = itemPath }
    return true
end
-- test:animal-group-registry:end

-- 材質快取：只快取成功——miss 交給引擎 nullTextures 負快取（Texture.java:479-480，
-- 同為 O(1) hash）；引擎把載入例外視為可重試、材質包重載也會清引擎快取，
-- 本地快取 false 會把暫時失敗變成整場永久消失
local adotsTexCache = {} -- [名稱] = Texture
function adotsTexture(name) -- local 前置宣告於統一視窗一節
    if not name then return nil end
    local t = adotsTexCache[name]
    if t == nil then
        t = getTexture(name)
        if t then adotsTexCache[name] = t end
    end
    return t
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
        st.flags = nil
        st.mode = nil
        st.username = nil
        st.hasPlayer = nil
        st.errLogged = nil
    end
    local now = getTimestampMs()
    local da = sandboxDist("AnimalIconDistance")
    local dv = sandboxDist("VehicleIconDistance")
    local livestockMode = livestockVisibilityMode()
    -- getSpecificPlayer/getX/getY 原版用例 ISMiniMap.lua:216-222；getUsername 原版用例
    -- ISScoreboard.lua:108。模式與 username 分欄入 cache key，避免拼接碰撞與換角沿用
    local playerObj = getSpecificPlayer(pn)
    local px = playerObj and playerObj:getX()
    local py = playerObj and playerObj:getY()
    local username = playerObj and playerObj:getUsername()
    local hasPlayer = playerObj ~= nil
    -- 開關組合＋篩選字串一起入 cache key：節流窗內任一變了就立即重取樣，
    -- 否則剛關掉的類別/物種會殘留舊點池最多 500ms。此 key 僅供節流判斷：
    -- 篩選欄位是 ESC 頁可手打的自由文字，就算打出含分隔符的怪值，
    -- 碰撞最壞也只是 ≤500ms 殘影、怪 token 過不了 group 比對＝惰性 no-op
    local disAnimal, rawA = adotsDisabledGroups("AnimalSpeciesFilter", ADOTS_SPECIES_UI)
    local disVeh, rawV = adotsDisabledGroups("VehicleCategoryFilter", ADOTS_VEHCAT_UI)
    local mask = (wantWild and 1 or 0) + (wantLive and 2 or 0) + (wantVeh and 4 or 0)
    local flags = tostring(mask) .. "|" .. tostring(da) .. "|" .. tostring(dv)
        .. "|" .. tostring(rawA) .. "|" .. tostring(rawV)
    if now < st.nextMs and st.flags == flags and st.mode == livestockMode
        and st.username == username and st.hasPlayer == hasPlayer then return st end
    st.flags = flags
    st.mode = livestockMode
    st.username = username
    st.hasPlayer = hasPlayer
    st.nextMs = now + ADOTS_INTERVAL_MS
    st.count = 0
    local cell = getCell()
    if not cell then return st end
    local minX, maxX, minY, maxY = visibleWorldAABB(inner) -- 可視框剔除（同殭屍取樣）
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
            log("動物/載具取樣失敗: " .. tostring(err))
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
--   本檔標題列 wrap 與 ISCollapsableWindow.lua:160 同序；
--   物品風格＝黑底方塊（drawRect）＋原色彩圖＋野生綠角標。
-- 白 glyph 繪製：黑影四斜角＋染色本體疊繪兩次（白 glyph 線條細、單次繪 alpha 偏淡，
-- 疊繪增濃；次數是實測調校旋鈕）——動物符號風格與載具共用
local function adotsDrawGlyph(inner, tex, ux, uy, size, r, g, b)
    inner:drawTextureScaled(tex, ux - 1, uy - 1, size, size, 0.85, 0, 0, 0)
    inner:drawTextureScaled(tex, ux + 1, uy - 1, size, size, 0.85, 0, 0, 0)
    inner:drawTextureScaled(tex, ux - 1, uy + 1, size, size, 0.85, 0, 0, 0)
    inner:drawTextureScaled(tex, ux + 1, uy + 1, size, size, 0.85, 0, 0, 0)
    inner:drawTextureScaled(tex, ux, uy, size, size, 1, r, g, b)
    inner:drawTextureScaled(tex, ux, uy, size, size, 1, r, g, b)
end

-- wildOpt/liveOpt/vehOpt＝該表面的開關選項（小地圖 AnimalWild…／世界地圖 WM 前綴）；
-- 風格/大小/顏色/物種與類別篩選、伺服器沙盒閘皆兩表面共用
local function drawAnimalDots(inner, wildOpt, liveOpt, vehOpt)
    local allowAnimals = sandboxGate("AllowAnimalDots", true) ~= false -- 伺服器沙盒閘門
    local wantWild = allowAnimals and getBoolOption(wildOpt, false)
    local wantLive = allowAnimals and getBoolOption(liveOpt, false)
    local wantVeh = getBoolOption(vehOpt, false)
        and sandboxGate("AllowVehicleDots", true) ~= false
    if not (wantWild or wantLive or wantVeh) then return end -- 全關＝零成本
    local st = sampleAnimalDots(inner, wantWild, wantLive, wantVeh)
    if st.count == 0 then return end
    local styleItem = getComboIndex("AnimalIconStyle", 1) == 2
    local sizeIdx = getComboIndex("AnimalIconSize", 2)
    local sizeSym = ADOTS_SIZES_SYM[sizeIdx] or 16
    -- 動物依風格選表；載具恆為 glyph → 恆用 SYM 尺寸（ITEM 表放大是針對彩圖模糊）
    local aSize = styleItem and (ADOTS_SIZES_ITEM[sizeIdx] or 20) or sizeSym
    -- 染色三下拉每幀讀值（同殭屍點顏色模式，存檔即生效）
    local wildC = adotsColor("AnimalWildColor", 2)
    local liveC = adotsColor("AnimalLivestockColor", 1)
    local vehC = adotsColor("VehicleIconColor", 4)
    local mapAPI = inner.mapAPI
    for i = 1, st.count do
        local d = st.dots[i]
        local size = d.veh and sizeSym or aSize
        local half = math.floor(size / 2) -- 圖標中心對齊目標位置
        local ux = mapAPI:worldToUIX(d.x, d.y) - half
        local uy = mapAPI:worldToUIY(d.x, d.y) - half
        -- 手動裁切同殭屍點位（Lua 繪製不吃元件裁切）；留 1px 邊給影子/描邊
        if ux >= 1 and uy >= 1 and ux + size <= inner.width - 1 and uy + size <= inner.height - 1 then
            if d.veh then -- 載具：恆用符號（無對應物品圖），顏色可自訂
                local tex = adotsTexture(ADOTS_VEH_SYM)
                if tex then
                    adotsDrawGlyph(inner, tex, ux, uy, size, vehC[1], vehC[2], vehC[3])
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
                        inner:drawRect(ux - 1, uy - 1, size + 2, size + 2, 0.75, 0, 0, 0)
                        inner:drawTextureScaled(tex, ux, uy, size, size, 1, 1, 1, 1)
                        if d.wild then -- 角標＝野生（彩圖不可染色，用角標區分；色跟野生下拉）
                            inner:drawRect(ux + size - 3, uy - 1, 4, 4, 1,
                                wildC[1], wildC[2], wildC[3])
                        end
                    else
                        local c = d.wild and wildC or liveC
                        adotsDrawGlyph(inner, tex, ux, uy, size, c[1], c[2], c[3])
                    end
                end
            end
        end
    end
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

-- test:safehouse-distance:start
local function drawSafehouses(inner)
    if not (SafeHouse and SafeHouse.getSafehouseList) then return end
    if not getBoolOption("Safehouses", true) then return end
    local dist = sandboxDist("SafehouseDisplayDistance")
    -- 沙盒顯示模式：1=關閉、2=僅自己的、3=全部（預設；缺表視為 3）
    local shMode = sandboxGate("SafehouseDisplay", 3)
    if shMode == 1 then return end
    local list = SafeHouse.getSafehouseList()
    if not list or list:size() == 0 then return end
    -- getSpecificPlayer/getX/getY 原版用例 ISMiniMap.lua:216-222；getUsername 原版用例
    -- ISScoreboard.lua:108。距離啟用但缺玩家時全部 fail closed
    local playerObj = getSpecificPlayer(inner.playerNum or 0)
    if dist and not playerObj then return end
    local px = playerObj and playerObj:getX()
    local py = playerObj and playerObj:getY()
    local username = playerObj and playerObj:getUsername()
    local dist2 = dist and dist * dist
    local mapAPI = inner.mapAPI
    for i = 0, list:size() - 1 do
        local sh = list:get(i)
        -- 安全屋幾何 getter＝SafeHouse.java:596-633；getX2/getY2 回 x+w/y+h
        local x1, y1 = sh:getX(), sh:getY()
        local x2, y2 = sh:getX2(), sh:getY2()
        -- 成員判定走 String 版 playerAllowed（SafeHouse.java:290-292，只查
        -- owner＋players）——IsoPlayer 版（:284-287）含管理員 CanGoInsideSafehouses
        -- 後門，admin 測試會全判綠
        local mine = username ~= nil and sh:playerAllowed(username)
        local visible = shMode ~= 2 or mine -- 模式 2＝僅畫自己所屬的
        if visible and dist2 then
            -- 玩家點到矩形的最近點；x2/y2 沿用上方原版 getter 原值
            local nx = math.max(x1, math.min(px, x2))
            local ny = math.max(y1, math.min(py, y2))
            local dx, dy = px - nx, py - ny
            visible = dx * dx + dy * dy <= dist2
        end
        if visible then
            -- 四角投影（worldToUIX/Y 同殭屍點位；等軸測下矩形成菱形故逐邊畫線）
            local ux1, uy1 = mapAPI:worldToUIX(x1, y1), mapAPI:worldToUIY(x1, y1)
            local ux2, uy2 = mapAPI:worldToUIX(x2, y1), mapAPI:worldToUIY(x2, y1)
            local ux3, uy3 = mapAPI:worldToUIX(x2, y2), mapAPI:worldToUIY(x2, y2)
            local ux4, uy4 = mapAPI:worldToUIX(x1, y2), mapAPI:worldToUIY(x1, y2)
            local r, g, b = 1.0, 0.25, 0.2            -- 他人＝紅
            if mine then r, g, b = 0.25, 0.95, 0.35 end -- 自己＝綠
            drawClippedEdge(inner, ux1, uy1, ux2, uy2, r, g, b)
            drawClippedEdge(inner, ux2, uy2, ux3, uy3, r, g, b)
            drawClippedEdge(inner, ux3, uy3, ux4, uy4, r, g, b)
            drawClippedEdge(inner, ux4, uy4, ux1, uy1, r, g, b)
        end
    end
end
-- test:safehouse-distance:end

--------------------------------------------------------------------------------
-- MOD 地圖範圍框線＋名稱（MapBounds，預設開）：對 manifest 裡「已啟用的地圖 MOD」
-- 依 bounds 畫青色框線，名稱畫在範圍中心（僅中心落在視窗內時畫——拉遠總覽定位用）。
-- 畫法同安全屋：四角 worldToUIX/Y 投影＋逐邊裁切畫線（等軸測下矩形成菱形）；
-- 名稱底墊同導航 label（drawRect 深底＋drawText，ISUIElement.lua:1191/1293）。
-- 只依賴 inner.mapAPI/.width/.height 與 ISUIElement 繪製方法——
-- 角落小地圖（ISMiniMapInner）與世界地圖（ISWorldMap，mapAPI 同為 getAPIv3，
-- ISWorldMap.lua:268）共用本函式。
--------------------------------------------------------------------------------
-- 框線顏色表：索引對應 MapBoundsColor 下拉順序。預設（第 1 位）＝綠——
-- getComboIndex 的 fallback 是索引 1，選項缺席時畫的也要是預設色
local MAPB_COLORS = {
    { 0.3, 0.95, 0.4 },  -- 綠（預設）
    { 0.35, 0.8, 1.0 },  -- 青
    { 1.0, 0.85, 0.25 }, -- 黃
    { 0.8, 0.45, 1.0 },  -- 紫
    { 1.0, 1.0, 1.0 },   -- 白
}

local function drawMapBounds(inner)
    if #mapOverlays == 0 then return end
    if not getBoolOption("MapBounds", true) then return end
    local c = MAPB_COLORS[getComboIndex("MapBoundsColor", 1)] or MAPB_COLORS[1]
    local mapAPI = inner.mapAPI
    for i = 1, #mapOverlays do
        local ov = mapOverlays[i]
        local x1, y1, x2, y2 = ov.bounds[1], ov.bounds[2], ov.bounds[3], ov.bounds[4]
        local ux1, uy1 = mapAPI:worldToUIX(x1, y1), mapAPI:worldToUIY(x1, y1)
        local ux2, uy2 = mapAPI:worldToUIX(x2, y1), mapAPI:worldToUIY(x2, y1)
        local ux3, uy3 = mapAPI:worldToUIX(x2, y2), mapAPI:worldToUIY(x2, y2)
        local ux4, uy4 = mapAPI:worldToUIX(x1, y2), mapAPI:worldToUIY(x1, y2)
        drawClippedEdge(inner, ux1, uy1, ux2, uy2, c[1], c[2], c[3])
        drawClippedEdge(inner, ux2, uy2, ux3, uy3, c[1], c[2], c[3])
        drawClippedEdge(inner, ux3, uy3, ux4, uy4, c[1], c[2], c[3])
        drawClippedEdge(inner, ux4, uy4, ux1, uy1, c[1], c[2], c[3])
        -- 名稱：缺譯退 mod ID（慣例同齒輪面板 getTextOrNull(label) or id）；
        -- nameKey 為 nil 時不可傳入 getTextOrNull（Java 端 startsWith 會 NPE，
        -- Translator.java:324）
        local name = (ov.nameKey and getTextOrNull(ov.nameKey)) or ov.mapMod
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
        -- 世界地圖圖標：獨立 WM* 開關（統一視窗「世界地圖圖標」區），
        -- 風格/顏色/篩選與小地圖共用。客戶端只知道已載入區域的個體，
        -- 拉遠不會鋪滿全圖——圖標天然只出現在玩家周邊。
        -- 畫在 original prerender「之前」：引擎地圖本體在 Java 層早已畫完
        -- （UIWorldMap.java:152→317 才進 Lua prerender），而 original 內含
        -- 註記編輯預覽（ISWorldMapSymbols.lua:1459）——先畫圖標，預覽才不被反蓋。
        -- 持久繪製錯誤首次記 log（同小地圖動物繪製的 log-once 策略）
        local adOk, adErr = pcall(drawAnimalDots, self, "WMAnimalWild", "WMAnimalLivestock", "WMVehicleDots")
        if not adOk and not self._minidoracatWMADotsErrLogged then
            self._minidoracatWMADotsErrLogged = true
            log("世界地圖動物圖標繪製失敗: " .. tostring(adErr))
        end
        local zdOk, zdErr = pcall(drawZombieDotsOn, self, "WMZombieDots")
        if not zdOk and not self._minidoracatWMZDotsErrLogged then
            self._minidoracatWMZDotsErrLogged = true
            log("世界地圖殭屍點繪製失敗: " .. tostring(zdErr))
        end
        originalWorldMapPrerender(self)
        pcall(drawMapBounds, self)
    end
end

-- 世界地圖按鈕列加「爪印」鈕＝開統一設定視窗（實測回饋：玩家在世界地圖上
-- 找不到圖標開關——入口必須在人所在的表面）。原版按鈕鏈狀排列後 shrinkWrap
-- 右貼齊（ISWorldMap.lua:299-356），事後插入須重算：新鈕接在 forget(?) 之後、
-- 關閉鈕前，closeBtn 右移、面板重新縮包＋右貼齊
if ISWorldMap and ISWorldMap.createChildren then
    local originalWMCreateChildren = ISWorldMap.createChildren
    function ISWorldMap:createChildren()
        originalWMCreateChildren(self)
        -- pcall 邊界：這段是對原版排版的事後手術（依賴 closeBtn/buttonPanel 欄位與
        -- shrinkWrap 行為），例外若外洩會沿 createChildren→ISWorldMap:new 炸掉整張
        -- 世界地圖——失敗只該損失爪印鈕（小地圖齒輪仍是入口）
        local ok, err = pcall(function()
            if self._minidoracatWMBtn then return end -- 冪等：重跑不重複插鈕
            if not (modOptions and self.buttonPanel and self.closeBtn) then return end
            local btnSize = self.closeBtn.height
            local btn = ISButton:new(self.closeBtn.x, 0, btnSize, btnSize, "", self,
                function(target) toggleSettingsWindow(target) end)
            btn:initialise()
            local paw = adotsTexture and adotsTexture("media/ui/LootableMaps/map_pawprint.png")
            if paw then
                btn:setImage(paw) -- setImage/forceImageSize 用法同原版 optionBtn（:309-310）
                btn:forceImageSize(math.floor(btnSize * 0.6), math.floor(btnSize * 0.6))
            else
                btn:setTitle("i")
            end
            btn.tooltip = getText("UI_MinidoracatMiniMap_BtnSettings")
            self.buttonPanel:addChild(btn)
            self.closeBtn:setX(btn:getRight() + 10) -- 10＝UI_BORDER_SPACING（ISWorldMap.lua:8，原版按鈕間距 :314/:351 用它）
            self.buttonPanel:shrinkWrap(0, 0, nil)
            self.buttonPanel:setX(self.width - 10 - self.buttonPanel.width)
            self._minidoracatWMBtn = btn
            -- ponytail: 未登記手把導航列（同小地圖新鈕的取捨——事後補列會亂序），
            -- 手把用戶走 ESC 選項頁（PZAPI ModOptions 已列全部開關；引擎原生三項
            -- 原版世界地圖選項面板本就可及），需要時再補登記
        end)
        if not ok then
            log("世界地圖爪印鈕安裝失敗: " .. tostring(err))
        end
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

-- 沙盒關閉時清掉送、收兩側本機 cache；持續為 false 時也會清除延遲抵達的封包。
-- Events.OnTick.Add 原版用例 client/Chat/ISChat.lua:943。
local lastAllowNavShare = sandboxGate("AllowNavShare", true) ~= false
-- test:nav-share-gate:start
local function navShareGateTick()
    local allowed = sandboxGate("AllowNavShare", true) ~= false
    if not allowed and (lastAllowNavShare or next(navShared) or next(sharedTargets)) then
        navShared = {}
        sharedTargets = {}
    end
    lastAllowNavShare = allowed
end

-- 關閉期間到達的舊封包直接丟棄，避免「最後一個 false tick 後收到、重開前未清」復活。
local function navAcceptShared(to, author, x, y)
    if sandboxGate("AllowNavShare", true) == false then return end
    sharedTargets[to] = sharedTargets[to] or {}
    sharedTargets[to][author] = { x = x, y = y }
end
-- test:nav-share-gate:end
Events.OnTick.Add(navShareGateTick)

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
    -- 陣營分享來的：只畫「給這位玩家」的桶（青旗＋名字）；getUsername 原版用例
    -- ISScoreboard.lua:108。已收到的目標仍受目前 AllowNavShare 閘門即時控制
    local bucket = sandboxGate("AllowNavShare", true) ~= false
        and playerObj and sharedTargets[playerObj:getUsername()]
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
        navAcceptShared(args.to, args.author, args.x, args.y)
    elseif command == "clearShared" and args.author and args.to then
        local bucket = sharedTargets[args.to]
        if bucket then bucket[args.author] = nil end
    end
end)

if ISMiniMapInner and ISMiniMapInner.prerender then
    local originalInnerPrerender = ISMiniMapInner.prerender
    function ISMiniMapInner:prerender()
        originalInnerPrerender(self)
        -- 沙盒禁用殭屍熱度時每幀壓回；重新允許時恢復（雙向即時）。
        -- 以實例旗標記住「是本閘門壓過」才恢復；恢復值讀 ModOptions——面板勾選
        -- 已回寫 ModOptions（見齒輪面板 onTickBox wrap），它即單一真相，
        -- 壓制期間玩家改勾選也會在重新允許時恢復成玩家要的值。
        -- 無 PZAPI（面板不回寫）時維持舊行為：恢復為開
        if sandboxGate("AllowZombieIntensity", true) == false then
            if self.mapAPI:getBoolean("ZombieIntensity") then
                self._minidoracatZISuppressed = true
                self.mapAPI:setBoolean("ZombieIntensity", false)
            end
        elseif self._minidoracatZISuppressed then
            self._minidoracatZISuppressed = nil
            self.mapAPI:setBoolean("ZombieIntensity",
                modOptions == nil or getBoolOption("ZombieIntensity", false))
        end
        pcall(drawSafehouses, self) -- pcall 防清單併發增刪（同殭屍取樣的防禦策略）
        pcall(drawMapBounds, self)
        pcall(drawNavTargets, self)
        -- 動物圖標（畫在殭屍點位之下：殭屍小點蓋大圖標可辨）。持久錯誤首次記 log
        -- 免全靜默（API 漂移/第三方動物資料異常可診斷；既有三個 pcall 沿舊慣例不動）
        local adOk, adErr = pcall(drawAnimalDots, self, "AnimalWild", "AnimalLivestock", "VehicleDots")
        if not adOk and not self._minidoracatADotsErrLogged then
            self._minidoracatADotsErrLogged = true
            log("動物圖標繪製失敗: " .. tostring(adErr))
        end
        -- 自由查看「已離開跟隨」提示（導航軟體回中提示的同款模式）：拖離後地圖
        -- 底部浮出琥珀色膠囊＋C 鈕同步高亮——點地圖本就會回中（onMouseUp 清旗標），
        -- 這裡只補視覺提醒，回中即消失（實測回饋：玩家不知道為何地圖不跟人）
        local flOn = self._minidoracatFreelook and getBoolOption("FreeLook", true)
        if flOn then
            local hint = getText("UI_MinidoracatMiniMap_FreelookHint")
            local tm = getTextManager()
            local hw = tm:MeasureStringX(UIFont.Small, hint)
            local fh = tm:getFontHeight(UIFont.Small)
            local hx = math.floor((self.width - hw) / 2)
            local hy = self.height - fh - 10
            self:drawRect(hx - 8, hy - 3, hw + 16, fh + 6, 0.72, 0, 0, 0)
            self:drawText(hint, hx, hy, 1, 0.85, 0.4, 1, UIFont.Small)
        end
        local cBtn = self.parent and self.parent._minidoracatCenterBtn
        if cBtn then -- C 鈕琥珀高亮＝次要提示；還原值同建立時的原版灰框
            cBtn.borderColor.r = flOn and 1 or 0.4
            cBtn.borderColor.g = flOn and 0.85 or 0.4
            cBtn.borderColor.b = 0.4
        end
        drawZombieDotsOn(self, "ZombieDots") -- 繪製本體共用化（世界地圖用 WMZombieDots）
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
