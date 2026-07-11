-- MinidoracatMiniMap.lua
-- Minidoracat MiniMap for B42 — 世界地圖 ImagePyramid 疊加層（client 端，單機/多人皆同）
--
-- 架構（基底 + addon 同檔名匹配，詳見專案 README.md 與
-- MinidoracatMapRendering/docs/minimap-mod-design.md「同名檔案設計」一節）：
--   所有 MOD（含本 MOD 自己，不特判）在 media/minimap/ 放同名 pyramid zip（CANONICAL）。
--   世界地圖初始化後掃描 getActivatedMods()，檔案存在即 mapAPI:addImagePyramid(絕對路徑)。
--   單一 Pyramid 樣式層以檔名「尾綴匹配」全部已掛載 zip
--   （WorldMapPyramidStyleLayer.java: endsWith(File.separator + fileName)），
--   每顆 zip 自帶 bounds 自動對位，後註冊者（addon）畫在先註冊者（基底）之上。

local CANONICAL = "minidoracat_minimap.pyramid.zip"
local LAYER_ID = "minidoracat_minimap"

local function log(msg)
    print("[MinidoracatMiniMap] " .. tostring(msg))
end

-- 掃描所有啟用 MOD，回傳含約定 zip 的絕對路徑清單
local function collectPyramidPaths()
    local paths = {}
    -- 必須用平台分隔符組路徑：Pyramid 樣式層以 endsWith(File.separator .. fileName)
    -- 匹配 zip，Windows 上用 "/" 串檔名會導致圖層永遠匹配不到
    local sep = getFileSeparator()
    local mods = getActivatedMods()
    for i = 1, mods:size() do
        local modID = mods:get(i - 1)
        local modInfo = getModInfoByID(modID)
        if modInfo then
            -- B42 的 media 一律在版本目錄（42/）或 common/ 之下，不在 MOD 根目錄
            -- （ChooseGameInfo.Mod 建構子；getVersionDir/getCommonDir 皆回傳絕對路徑）。
            -- 版本目錄優先（與遊戲的 version-覆蓋-common 語意一致），每個 MOD 只取一顆。
            for _, root in ipairs({ modInfo:getVersionDir(), modInfo:getCommonDir() }) do
                if root then
                    local path = root .. sep .. "media" .. sep .. "minimap" .. sep .. CANONICAL
                    if fileExists(path) then
                        table.insert(paths, path)
                        break
                    end
                end
            end
        end
    end
    return paths
end

local function applyMiniMapPyramids(mapUI)
    local mapAPI = mapUI.mapAPI
    local styleAPI = mapAPI:getStyleAPI()

    local paths = collectPyramidPaths()
    if #paths == 0 then
        log("未找到任何 " .. CANONICAL .. "，不加圖層")
        return
    end

    -- 掛載 zip（Java 側 WorldMap.addImagePyramid 自帶去重，重開地圖重複呼叫安全）
    for _, path in ipairs(paths) do
        mapAPI:addImagePyramid(path)
        log("已掛載 pyramid: " .. path)
    end

    -- 樣式層：疊在原版樣式之上，不清空原版（刻意不學 showTerrainImage 的 styleAPI:clear()）
    -- 防重複註冊：重跑初始化時圖層已存在就不重加
    if styleAPI:indexOfLayer(LAYER_ID) == -1 then
        local layer = styleAPI:newPyramidLayer(LAYER_ID)
        layer:setPyramidFileName(CANONICAL)
        layer:addFill(0.0, 255.0, 255.0, 255.0, 255.0)
    end

    mapAPI:setBoolean("ImagePyramid", true)
    log("圖層就緒（" .. #paths .. " 個 pyramid zip）")
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
    mapAPI:setBoolean("PlaceNames", getBoolOption("PlaceNames", true))
end

if PZAPI and PZAPI.ModOptions then
    modOptions = PZAPI.ModOptions:create("MinidoracatMiniMap", "UI_MinidoracatMiniMap_Options")

    -- 注意：combobox 的 tooltip 在 MainOptions.lua（2942-2965）沒有被顯示，故不設
    local sizeCombo = modOptions:addComboBox("MapSize", "UI_MinidoracatMiniMap_Size")
    sizeCombo:addItem("UI_MinidoracatMiniMap_Size_Small", false)
    sizeCombo:addItem("UI_MinidoracatMiniMap_Size_Medium", true) -- 預設「中」
    sizeCombo:addItem("UI_MinidoracatMiniMap_Size_Large", false)
    sizeCombo:addItem("UI_MinidoracatMiniMap_Size_Huge", false)

    modOptions:addTickBox("Players", "UI_MinidoracatMiniMap_Players", true,
        "UI_MinidoracatMiniMap_Players_tooltip")
    modOptions:addTickBox("RemotePlayers", "UI_MinidoracatMiniMap_RemotePlayers", true,
        "UI_MinidoracatMiniMap_RemotePlayers_tooltip")
    modOptions:addTickBox("ZombieIntensity", "UI_MinidoracatMiniMap_ZombieIntensity", false,
        "UI_MinidoracatMiniMap_ZombieIntensity_tooltip")
    modOptions:addTickBox("PlaceNames", "UI_MinidoracatMiniMap_PlaceNames", true,
        "UI_MinidoracatMiniMap_PlaceNames_tooltip")

    -- 按「接受/套用」時由 MainOptions:apply 呼叫（3789）。該函式先跑 gameOptions:apply()
    -- （3787）把 UI 值寫回 option，所以此處 getValue() 已是新值。
    -- 無小地圖（主選單、沙盒未開 AllowMiniMap、尚未開圖）時只存值不動作。
    function modOptions:apply()
        if not getSpecificPlayer(0) then return end
        local mm = getPlayerMiniMap(0)
        if not mm then return end
        -- ponytail: 只處理 player 0，分割畫面其餘玩家沿用原版（原版 saveSettings 也只存 player 0）
        if mm._minidoracatSizeIndex ~= getSizeIndex() then
            -- 尺寸變更：整個重建；我們 hook 的 InitPlayer 會重套尺寸、pyramid 與開關
            ISMiniMap.Recreate(0)
        elseif mm.inner and mm.inner.mapAPI then
            applyToggleOptions(mm.inner.mapAPI) -- 純開關直接寫 mapAPI，即時生效
        end
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
        local minimap
        if scale ~= 1.0 and ISMiniMapOuter then
            local originalNew = ISMiniMapOuter.new
            ISMiniMapOuter.new = function(self, x, y, width, height, pn)
                local w = math.floor(width * scale + 0.5)
                local h = math.floor(height * scale + 0.5)
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
            if minimap.inner and minimap.inner.mapAPI then
                local ok, err = pcall(applyMiniMapPyramids, minimap.inner)
                if not ok then
                    log("小地圖初始化失敗: " .. tostring(err))
                end
                pcall(applyToggleOptions, minimap.inner.mapAPI)
            end
        end
        return minimap
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

log("已載入（hook ISWorldMap:initDataAndStyle + ISMiniMap.InitPlayer + 齒輪面板 + 快捷鍵 + MOD 選項）")
