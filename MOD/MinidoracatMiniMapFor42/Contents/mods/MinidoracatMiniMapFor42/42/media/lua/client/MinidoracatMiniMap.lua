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
    mapAPI:setBoolean("PlaceNames", getBoolOption("PlaceNames", true))
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
    modOptions:addTickBox("ZombieIntensity", "UI_MinidoracatMiniMap_ZombieIntensity", false,
        "UI_MinidoracatMiniMap_ZombieIntensity_tooltip")
    modOptions:addTickBox("PlaceNames", "UI_MinidoracatMiniMap_PlaceNames", true,
        "UI_MinidoracatMiniMap_PlaceNames_tooltip")
    -- 精準殭屍點位（預設關）；齒輪面板另以自訂 ISTickBox 注入同步開關
    -- （它原生只列引擎選項物件，這是純 Lua 自繪——見下方「齒輪面板」一節）
    modOptions:addTickBox("ZombieDots", "UI_MinidoracatMiniMap_ZombieDots", false,
        "UI_MinidoracatMiniMap_ZombieDots_tooltip")
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
            end
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

-- 齒輪面板追加「殭屍點位」開關（問題 C）：面板原生 createChildren 只列引擎選項
-- 物件（getVisibleOptions → ISTickBox/ISTextEntryBox，ISMiniMap.lua:45-78），
-- 殭屍點位是本 MOD 純 Lua 自繪、無對應引擎選項——wrap createChildren 在原清單
-- 之後注入自訂 ISTickBox（建法對照原版 ISMiniMap.lua:48-57），勾選直接寫回
-- ModOptions 並立即存檔。無 PZAPI（modOptions 為 nil，值無處持久化）時不注入。
if ISMiniMapOptionsPanel and ISMiniMapOptionsPanel.createChildren
    and ISMiniMapOptionsPanel.synchUI and ISTickBox then

    -- 勾選變更 handler：ISTickBox 回呼簽名 (target, index, selected, args...)
    -- （ISTickBox.lua:175-176；原版 handler 同款 ISMiniMap.lua:14）
    function ISMiniMapOptionsPanel:onMinidoracatZombieDots(index, selected)
        if not modOptions then return end
        local opt = modOptions:getOption("ZombieDots")
        if not opt then return end
        opt:setValue(selected) -- option.setValue 會同步 MOD 選項頁的 element（ModOptions.lua:68-73）
        PZAPI.ModOptions:save() -- 立即落地 ModOptions.ini（PZAPI/ModOptions.lua:259）
        -- 繪製端（ISMiniMapInner:prerender wrap）每幀讀選項值，這裡不用另外通知
    end

    local originalPanelCreateChildren = ISMiniMapOptionsPanel.createChildren
    function ISMiniMapOptionsPanel:createChildren()
        originalPanelCreateChildren(self)
        if not modOptions then return end
        -- 原版收尾以「子元件最大 bottom＋resizeWidgetHeight」定面板高
        -- （ISMiniMap.lua:80-87），故內容底 = self.height - resizeWidgetHeight()；
        -- 注入點＝內容底再空 6px（同原版行距），面板加高同額
        local entryHgt = getTextManager():getFontHeight(UIFont.Small) + 6 -- BUTTON_HGT（ISMiniMap.lua:7-9）
        local xPad = 10 + 1 -- UI_BORDER_SPACING + 1（ISMiniMap.lua:8/29）
        local y = self.height - self:resizeWidgetHeight() + 6
        -- ISTickBox:new(x,y,w,h,name,target,method,...)＝ISTickBox.lua:282；用法同 ISMiniMap.lua:48
        local tickBox = ISTickBox:new(xPad, y, self.width, entryHgt, "", self,
            self.onMinidoracatZombieDots)
        tickBox:initialise()
        -- addOption＝ISTickBox.lua:227；標籤沿用齒輪面板翻譯鍵慣例（ISMiniMap.lua:50）
        tickBox:addOption(getTextOrNull("IGUI_MapOption_ZombieDots") or "ZombieDots")
        tickBox:setSelected(1, getBoolOption("ZombieDots", false)) -- setSelected＝ISTickBox.lua:51
        tickBox:setWidthToFit() -- ISTickBox.lua:266
        self:addChild(tickBox)
        self:insertNewLineOfButtons(tickBox) -- 手把導航登記（原版每列都登記，ISMiniMap.lua:57）
        -- 面板重建路徑（synchUI 全清子元件重跑 createChildren，ISMiniMap.lua:133-142）：
        -- 舊 tickbox 已被 removeChild，這裡蓋掉引用＝不重複、不殘留
        self._minidoracatZombieDots = tickBox
        self:setWidth(math.max(self.width, tickBox:getRight() + xPad))
        self:setHeight(self.height + entryHgt + 6)
    end

    local originalPanelSynchUI = ISMiniMapOptionsPanel.synchUI
    function ISMiniMapOptionsPanel:synchUI()
        originalPanelSynchUI(self)
        -- 每次開面板同步勾選狀態（值可能在 MOD 選項頁被改過）
        local box = self._minidoracatZombieDots
        if box then
            box:setSelected(1, getBoolOption("ZombieDots", false))
        end
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
local ZDOTS_SIZE = 3          -- 紅點邊長（px）
local ZDOTS_R, ZDOTS_G, ZDOTS_B, ZDOTS_A = 0.85, 0.1, 0.1, 0.85 -- 點色（rgba 可調常數）

local zdots = {}      -- (x,y) 快照池；槽位重用，不產生每幀垃圾
local zdotsCount = 0
local zdotsNextMs = 0

local function sampleZombieDots()
    local now = getTimestampMs()
    if now < zdotsNextMs then return end
    zdotsNextMs = now + ZDOTS_INTERVAL_MS
    zdotsCount = 0
    local cell = getCell()
    local list = cell and cell:getZombieList()
    if not list then return end
    -- pcall 防競態：getZombieList 是模擬端會增刪的活 ArrayList，size 與 get
    -- 之間殭屍被移除會丟 IndexOutOfBounds——失敗就放棄本輪取樣（300ms 後重試）
    local ok = pcall(function()
        local n = list:size()
        if n > ZDOTS_MAX then n = ZDOTS_MAX end
        for i = 1, n do
            local z = list:get(i - 1)
            local d = zdots[i]
            if not d then d = {}; zdots[i] = d end
            d.x = z:getX()
            d.y = z:getY()
            zdotsCount = i
        end
    end)
    if not ok then zdotsCount = 0 end
end

if ISMiniMapInner and ISMiniMapInner.prerender then
    local originalInnerPrerender = ISMiniMapInner.prerender
    function ISMiniMapInner:prerender()
        originalInnerPrerender(self)
        if not getBoolOption("ZombieDots", false) then return end -- 關閉＝零成本
        sampleZombieDots()
        local mapAPI = self.mapAPI
        for i = 1, zdotsCount do
            local d = zdots[i]
            -- 世界→UI 座標：worldToUIX/Y＝UIWorldMapV1.java:298/311
            -- （mapAPI 是 getAPIv3，V3→V2→V1 繼承鏈 UIWorldMapV3.java:10、V2.java:8）；
            -- 原版用例 ISMultiplayerZoneEditor.lua:83 + MultiplayerZoneEditorMode_NonPVP.lua:58
            local ux = mapAPI:worldToUIX(d.x, d.y)
            local uy = mapAPI:worldToUIY(d.x, d.y)
            -- 手動裁到視窗內（Lua drawRect 不吃元件裁切）；點起繪於 ux-1、寬 3px，
            -- 邊界收 1/2px 免溢出 inner 疊到外框
            if ux >= 1 and uy >= 1 and ux <= self.width - 2 and uy <= self.height - 2 then
                -- drawRect＝ISUIElement.lua:1191（引數 x,y,w,h,a,r,g,b）
                self:drawRect(ux - 1, uy - 1, ZDOTS_SIZE, ZDOTS_SIZE, ZDOTS_A, ZDOTS_R, ZDOTS_G, ZDOTS_B)
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
        -- 把手只在 adornments 展開（滑鼠在小地圖上）或拖曳中顯示，平常零干擾
        if st or (self.titleBar and self.titleBar:isVisible()) then
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
