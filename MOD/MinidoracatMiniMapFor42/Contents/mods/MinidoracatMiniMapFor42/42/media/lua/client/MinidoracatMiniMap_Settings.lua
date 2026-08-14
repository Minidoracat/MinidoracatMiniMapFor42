-- MinidoracatMiniMap_Settings.lua
-- 本檔範圍：統一控制視窗整節（自主檔 MinidoracatMiniMap.lua 拆出，內容原樣搬遷）——
-- UNIFIED_* 資料表、addon-conditional 選項的 OnGameBoot 追加、settingsApply 管線、
-- 篩選寫入、引擎選項直讀直寫、標題摘要、視窗重建/建立/開關。
-- 載入順序假設：PZ 依字母序載入同目錄 lua，'.'(0x2E) < '_'(0x5F) → 主檔必先載入並
-- 建好 MinidoracatMiniMapCore 命名空間；本檔載入期只讀取其「一次性賦值」的穩定引用
-- 並定義函式/掛事件，跨檔「函式呼叫」一律發生在事件/呼叫時。
-- 拆檔緣由：Kahlua 編譯器每個函式原型（含每檔主 chunk）locvar 上限 200
-- （LexState.new_localvar 固定陣列，超過＝整檔拒載），主檔與 unifiedRebuild 都曾貼頂
-- ——拆檔＝主 chunk 獨立額度；unifiedRebuild 再分解為頂層量測/建構函式（各自 200）。
local Core = MinidoracatMiniMapCore
-- ready＝主檔完整走完（版本檢查通過）才為真：拆分前本節位於主檔版本檢查之後，
-- 版本不符時整節不存在——此閘門維持同義行為
if not (Core and Core.ready) then return end

-- 主檔共用成員（皆為主檔載入期一次性賦值的穩定引用；modOptions 無 PZAPI 時為 nil，
-- 沿用原 nil 檢查。表引用共享同一實例：主檔 registerAnimalGroup/registerZoneAction
-- 等對表的後續插入，本檔在呼叫時讀到的即最新內容）
local modOptions = Core.modOptions
local getBoolOption = Core.getBoolOption
local getComboIndex = Core.getComboIndex
local getSliderValue = Core.getSliderValue
local sandboxGate = Core.sandboxGate
local sandboxDist = Core.sandboxDist
local displayDist = Core.displayDist
local livestockVisibilityMode = Core.livestockVisibilityMode
local unifiedCsvSet = Core.unifiedCsvSet
local adotsTexture = Core.adotsTexture
local ADOTS_ART = Core.ADOTS_ART
local ADOTS_SPECIES_UI = Core.ADOTS_SPECIES_UI
local ADOTS_VEHCAT_UI = Core.ADOTS_VEHCAT_UI
local ADOTS_COLOR_ITEMS = Core.ADOTS_COLOR_ITEMS
local registeredZoneActions = Core.registeredZoneActions
local registeredPacks = Core.registeredPacks
local registeredZoneProviders = Core.registeredZoneProviders
local hasExternalZoneProvider = Core.hasExternalZoneProvider

--------------------------------------------------------------------------------
-- 統一控制視窗（免跑 ESC 選項頁）：
--   齒輪鈕開啟；五個可收合區塊（圖層/殭屍點位/動物/載具/外觀行為）整併
--   原設定視窗與圖層面板注入項——「=」鈕已退役，引擎原生三項
--   （等軸測/符號/遠端符號）移入「圖層顯示」區。
-- 視窗以 ISCollapsableWindow 頂層呈現（標題拖曳＋關閉鈕內建，
-- ISCollapsableWindow.lua:26-61），改值即寫回 ModOptions（同步 ESC 頁元件，
-- ModOptions.lua:68-73）並走既有 modOptions:apply()——尺寸重建/開關即時/
-- 透明度一條龍，不另寫套用邏輯。收合/展開/全選採「全清重建」模式
-- （同原版 synchUI 全重建先例，ISMiniMap.lua:133-142），免逐元件同步。
--------------------------------------------------------------------------------

-- 各區的下拉/勾選定義（沿用 settingsApply 管線；engine=true 直寫引擎選項——
-- 原版語意：Isometric/Symbols 由原版 saveSettings 跨場存 WorldMapSettings
-- （ISMiniMap.lua:605-616）、RemoteSymbols 原版即不持久化）
local UNIFIED_LAYER_TICKS = {
    -- 圖片化地圖總開關：經 settingsApply → modOptions:apply 觸發雙表面重建/卸載
    { id = "MapImagery", label = "UI_MinidoracatMiniMap_MapImagery", default = true },
    { id = "Players", label = "UI_MinidoracatMiniMap_Players", default = true },
    { id = "RemotePlayers", label = "UI_MinidoracatMiniMap_RemotePlayers", default = true, mpOnly = true },
    { id = "ZombieIntensity", label = "UI_MinidoracatMiniMap_ZombieIntensity", default = false },
    { id = "PlaceNames", label = "UI_MinidoracatMiniMap_PlaceNames", default = true },
    { id = "StreetNames", label = "UI_MinidoracatMiniMap_StreetNames", default = true },
    { id = "Safehouses", label = "UI_MinidoracatMiniMap_Safehouses", default = true },
    -- PoiIcons/PoiBlocks 移入獨立「資源點」區塊（poicat），與 ZoneLayer 解耦
    { id = "Isometric", label = "IGUI_MapOption_Isometric", engine = true },
    { id = "Symbols", label = "IGUI_MapOption_Symbols", engine = true },
    { id = "RemoteSymbols", label = "IGUI_MapOption_RemoteSymbols", engine = true },
}
local UNIFIED_ZOMBIE_COMBOS = {
    { id = "ZombieDotColor", label = "UI_MinidoracatMiniMap_ZombieDotColor", default = 1,
        items = { "UI_MinidoracatMiniMap_ZDotColor_Orange", "UI_MinidoracatMiniMap_ZDotColor_Yellow",
            "UI_MinidoracatMiniMap_ZDotColor_Purple", "UI_MinidoracatMiniMap_ZDotColor_White",
            "UI_MinidoracatMiniMap_ZDotColor_Red" } },
    { id = "ZombieDotMax", label = "UI_MinidoracatMiniMap_ZombieDotMax", default = 2,
        items = { "UI_MinidoracatMiniMap_ZDotMax_100", "UI_MinidoracatMiniMap_ZDotMax_200",
            "UI_MinidoracatMiniMap_ZDotMax_400", "UI_MinidoracatMiniMap_ZDotMax_800" } },
}
local UNIFIED_ANIMAL_COMBOS = {
    { id = "AnimalIconStyle", label = "UI_MinidoracatMiniMap_AnimalIconStyle", default = 1,
        items = { "UI_MinidoracatMiniMap_AIconStyle_Symbol", "UI_MinidoracatMiniMap_AIconStyle_Item" } },
    { id = "AnimalWildColor", label = "UI_MinidoracatMiniMap_AnimalWildColor", default = 2,
        items = ADOTS_COLOR_ITEMS },
    { id = "AnimalLivestockColor", label = "UI_MinidoracatMiniMap_AnimalLivestockColor", default = 1,
        items = ADOTS_COLOR_ITEMS },
}
local UNIFIED_VEHICLE_COMBOS = {
    { id = "VehicleIconColor", label = "UI_MinidoracatMiniMap_VehicleIconColor", default = 4,
        items = ADOTS_COLOR_ITEMS },
}
-- 滑條列（大小 px／透明度 %）：值即像素/百分比，繪製端每幀讀值→拖動即時預覽；
-- 落盤在滑鼠放開時（unifiedAddSliderRows 的 onMouseUp wrap，避免拖曳中高頻檔案 IO）。
-- 單一表包四群：Kahlua 編譯器每函式 locvar 上限 200（LexState.new_localvar 固定
-- 陣列）——拆檔後本檔主 chunk 餘裕充足，仍維持單表慣例（ini diff 穩定）
local UNIFIED_SLIDERS = {
    zombie = {
        { id = "ZombieDotSize", label = "UI_MinidoracatMiniMap_ZombieDotSize",
            default = 3, min = 1, max = 16, step = 1, fmt = "%dpx" },
        { id = "ZombieDotAlpha", label = "UI_MinidoracatMiniMap_IconAlpha",
            default = 100, min = 10, max = 100, step = 5, fmt = "%d%%" },
    },
    animals = {
        { id = "AnimalIconSize", label = "UI_MinidoracatMiniMap_AnimalIconSize",
            default = 16, min = 8, max = 48, step = 1, fmt = "%dpx" },
        { id = "AnimalIconAlpha", label = "UI_MinidoracatMiniMap_IconAlpha",
            default = 100, min = 10, max = 100, step = 5, fmt = "%d%%" },
    },
    vehicles = {
        { id = "VehicleIconSize", label = "UI_MinidoracatMiniMap_VehicleIconSize",
            default = 16, min = 8, max = 48, step = 1, fmt = "%dpx" },
        { id = "VehicleIconAlpha", label = "UI_MinidoracatMiniMap_IconAlpha",
            default = 100, min = 10, max = 100, step = 5, fmt = "%d%%" },
    },
    poi = {
        { id = "PoiIconSize", label = "UI_MinidoracatMiniMap_PoiIconSize",
            default = 18, min = 8, max = 48, step = 1, fmt = "%dpx" },
        { id = "PoiIconAlpha", label = "UI_MinidoracatMiniMap_IconAlpha",
            default = 100, min = 10, max = 100, step = 5, fmt = "%d%%" },
    },
    appearance = {
        { id = "GhostAlpha", label = "UI_MinidoracatMiniMap_GhostAlpha",
            default = 40, min = 10, max = 90, step = 5, fmt = "%d%%" },
    },
    -- 顯示距離（格；0＝不限制）：與伺服器沙盒距離經 displayDist 取較小者生效。
    -- capBy＝對應沙盒選項名——重建時滑條上限動態縮到伺服器有效上限（sandboxDist
    -- 已併全域上限 AllInfoDistance），玩家由此「看得到」伺服器允許範圍；
    -- zeroLabel＝0 值的數值標顯示字（不限），避免被誤讀成「0 格＝看不到」
    distance = {
        { id = "ClientZombieDotDistance", label = "UI_MinidoracatMiniMap_DistZombie",
            default = 0, min = 0, max = 2000, step = 1, fmt = "%d",
            zeroLabel = "UI_MinidoracatMiniMap_DistUnlimited", capBy = "ZombieDotDistance" },
        { id = "ClientAnimalIconDistance", label = "UI_MinidoracatMiniMap_DistAnimal",
            default = 0, min = 0, max = 2000, step = 1, fmt = "%d",
            zeroLabel = "UI_MinidoracatMiniMap_DistUnlimited", capBy = "AnimalIconDistance" },
        { id = "ClientVehicleIconDistance", label = "UI_MinidoracatMiniMap_DistVehicle",
            default = 0, min = 0, max = 2000, step = 1, fmt = "%d",
            zeroLabel = "UI_MinidoracatMiniMap_DistUnlimited", capBy = "VehicleIconDistance" },
        { id = "ClientSafehouseDisplayDistance", label = "UI_MinidoracatMiniMap_DistSafehouse",
            default = 0, min = 0, max = 2000, step = 1, fmt = "%d",
            zeroLabel = "UI_MinidoracatMiniMap_DistUnlimited", capBy = "SafehouseDisplayDistance" },
        { id = "ClientPoiDisplayDistance", label = "UI_MinidoracatMiniMap_DistPoi",
            default = 0, min = 0, max = 2000, step = 1, fmt = "%d",
            zeroLabel = "UI_MinidoracatMiniMap_DistUnlimited", capBy = "PoiDisplayDistance" },
    },
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
    { id = "ShowPlayerCoords", label = "UI_MinidoracatMiniMap_ShowPlayerCoords", default = true },
    { id = "ClickOpenWorldMap", label = "UI_MinidoracatMiniMap_ClickOpenWorldMap", default = false },
    { id = "TextAnnotations", label = "UI_MinidoracatMiniMap_TextAnnotations", default = false },
    { id = "LockPosition", label = "UI_MinidoracatMiniMap_LockPosition", default = false },
    { id = "GhostMode", label = "UI_MinidoracatMiniMap_GhostMode", default = false },
    -- 勾選經 settingsApply → modOptions:apply()，浮動圖標顯示更新掛在該處
    { id = "FloatIcon", label = "UI_MinidoracatMiniMap_FloatIcon", default = true },
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
    { id = "poicat", label = "UI_MinidoracatMiniMap_SecPOI" },
    { id = "distance", label = "UI_MinidoracatMiniMap_SecDistance" },
    { id = "zombie", label = "UI_MinidoracatMiniMap_SecZombie", gate = "AllowZombieDots" },
    { id = "animals", label = "UI_MinidoracatMiniMap_SecAnimals", gate = "AllowAnimalDots" },
    { id = "vehicles", label = "UI_MinidoracatMiniMap_SecVehicles", gate = "AllowVehicleDots" },
    { id = "worldmap", label = "UI_MinidoracatMiniMap_SecWorldMap" },
    { id = "appearance", label = "UI_MinidoracatMiniMap_SecAppearance" },
}
-- ponytail: 展開狀態 session 記憶即可，跨場記憶（存 ModOptions）是升級路徑。
-- 預設全部收合（實測回饋：每次開窗都先展開圖層顯示很煩）
local unifiedExpand = {}
-- 固定分欄（實測回饋：貪婪平衡會讓區塊隨展開狀態在左右欄跳動，破壞空間記憶）：
-- 左欄＝圖層顯示/資源點/外觀與行為，右欄＝殭屍點位/動物圖標/載具圖標/世界地圖圖標。
-- worldmap 置右欄：與同為「點位顯示」的殭屍/動物/載具同群（世界地圖圖標亦是這三類點位），
-- 且平衡兩欄全展開高度（資源點併入左欄後左重，右移 worldmap 後左右列數約略持平）
local UNIFIED_LANE = { layers = 1, poicat = 1, distance = 1, appearance = 1,
    zombie = 2, animals = 2, vehicles = 2, worldmap = 2 }
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
    -- 框線透明度：三檔沿用小地圖 Opacity 的翻譯鍵與語意
    local mbAlpha = modOptions:addComboBox("MapBoundsAlpha", "UI_MinidoracatMiniMap_MapBoundsAlpha")
    mbAlpha:addItem("UI_MinidoracatMiniMap_Opacity_Full", true) -- 順序須同 MAPB_ALPHAS
    mbAlpha:addItem("UI_MinidoracatMiniMap_Opacity_Half", false)
    mbAlpha:addItem("UI_MinidoracatMiniMap_Opacity_Faint", false)
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
    table.insert(UNIFIED_APPEAR_COMBOS, { id = "MapBoundsAlpha",
        label = "UI_MinidoracatMiniMap_MapBoundsAlpha", default = 1,
        items = { "UI_MinidoracatMiniMap_Opacity_Full", "UI_MinidoracatMiniMap_Opacity_Half",
            "UI_MinidoracatMiniMap_Opacity_Faint" } })
end)

-- Zone 圖層總開關（有「外部」zone provider 註冊才出現；內建 POI 不算——它繞過此閘）：
-- 註冊 ModOptions 選項本體＋統一視窗圖層區加項。齒輪面板那一面在主檔 GEAR 區已補；
-- 三面共用同一 ZoneLayer 選項。
Events.OnGameBoot.Add(function()
    if not hasExternalZoneProvider() or not modOptions then return end
    modOptions:addTickBox("ZoneLayer", "UI_MinidoracatMiniMap_ZoneLayer", true,
        "UI_MinidoracatMiniMap_ZoneLayer_tooltip")
    table.insert(UNIFIED_LAYER_TICKS, { id = "ZoneLayer",
        label = "UI_MinidoracatMiniMap_ZoneLayer", default = true })
    -- per-provider 母開關（provider 註冊時給了 optionLabelKey 才有；如 Zones addon 的
    -- 「顯示伺服器區域」）：ModOptions 選項本體＋統一視窗圖層區加項。渲染時
    -- drawZoneFill/Lines/Icons 依 optionKey 讀值，關＝整個 provider 跳過。
    for i = 1, #registeredZoneProviders do
        local p = registeredZoneProviders[i]
        if p.optionKey then
            modOptions:addTickBox(p.optionKey, p.optionLabelKey, true)
            table.insert(UNIFIED_LAYER_TICKS, { id = p.optionKey,
                label = p.optionLabelKey, default = true })
        end
    end
    -- 伺服器區域專屬設定（同本條件：有外部 provider 才出現）——
    -- 名稱遠距開關＋類別篩選 CSV（統一視窗類別勾選自動寫入；空/'-'＝全開）。
    -- 統一視窗「伺服器區域」區塊亦在此動態插入（插在資源點之後、左欄）
    modOptions:addTickBox("ZoneNamesFar", "UI_MinidoracatMiniMap_ZoneNamesFar", true,
        "UI_MinidoracatMiniMap_ZoneNamesFar_tooltip")
    modOptions:addTextEntry("ZoneCategoryFilter", "UI_MinidoracatMiniMap_ZoneCategoryFilter", "",
        "UI_MinidoracatMiniMap_ZoneCategoryFilter_tooltip")
    table.insert(UNIFIED_SECTIONS, 3, { id = "zones", label = "UI_MinidoracatMiniMap_SecZones" })
    UNIFIED_LANE.zones = 1
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

-- 篩選寫入：單鍵切換／全選全不選；序列化依定義序（ini diff 穩定）。
-- 不呼叫 apply()——取樣端下輪（≤0.5s）經 cache key 察覺變更。
-- CSV 讀取端（unifiedCsvSet/adotsDisabledGroups）在主檔：取樣端每輪要用
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
    -- 空集合寫 "-"（見主檔 unifiedCsvSet 註解的 PZAPI 空字串髒化問題）
    opt:setValue(#parts > 0 and table.concat(parts, ",") or "-")
    PZAPI.ModOptions:save()
end
local function unifiedSetAllFilter(optId, uiDefs, enabled)
    if not modOptions then return end
    local opt = modOptions:getOption(optId)
    if not opt then return end
    if enabled then
        opt:setValue("-") -- 空集合 sentinel（見主檔 unifiedCsvSet 註解）
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
    elseif sec.id == "poicat" then
        local order = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.ORDER
        if type(order) ~= "table" then return nil end
        local on = 0
        for i = 1, #order do
            if getBoolOption("Cat_" .. order[i], true) then on = on + 1 end
        end
        return on .. "/" .. #order
    elseif sec.id == "distance" then
        -- 有距離限制生效（伺服器或玩家任一）之項目數；0/5＝全不限
        if not displayDist then return nil end
        local on = 0
        for i = 1, #UNIFIED_SLIDERS.distance do
            local capBy = UNIFIED_SLIDERS.distance[i].capBy
            if capBy and displayDist(capBy) then on = on + 1 end
        end
        return on .. "/" .. #UNIFIED_SLIDERS.distance
    end
    return nil
end

--------------------------------------------------------------------------------
-- unifiedRebuild 分解（拆檔重構）：原單一函式自身曾撞 Kahlua 200 locvar 上限
-- （實測 211 → 整檔載入失敗）。現拆為：量測（unifiedMeasureLayout）＋通用列
-- helpers（unifiedAdd*）＋各區塊 builder（unifiedBuild*）——每個頂層函式自帶
-- 獨立 200 額度，unifiedRebuild 本體只留版面計算與分派。
-- ctx＝單次重建的共享狀態（原閉包上值改明取）：win/panel/pn/量測結果與
-- curX/curY 游標（builder 讀寫 curY，座標皆為 panel 內容座標，捲動由 panel 處理）。
--------------------------------------------------------------------------------
local unifiedRebuild -- 前置宣告：helpers/builders 的回呼要遞迴重建（本體在下方）

-- 標籤實測寬（MeasureStringX 用例 ISMiniMap.lua:31）；量測與 builder 零星用
local function utw(t) return getTextManager():MeasureStringX(UIFont.Small, t) end

local function unifiedAdd(ctx, el)
    -- 捲動面板子元件的 y 是「內容座標」，必須關掉 keepOnScreen——否則任何 setY/setHeight
    -- 會把 y 夾到 getScreenHeight()-height（ISUIElement.lua:209-219/245-257 的螢幕夾制，
    -- 設計給頂層視窗），內容超過一屏的列會被硬拉回 985 疊在一起（實機 MMdbg 探針證據）。
    el.keepOnScreen = false
    ctx.panel:addChild(el)
    -- 子元件隨捲動位移的真正開關是 panel 的 java 端 scrollChildren（buildSettingsWindow
    -- 於 instantiate 後設定）；child.scrollWithParent 預設即 true（UIElement.java:46），
    -- 兩者同真時 getAbsoluteY 才會加上 panel.getYScroll（UIElement.java:918-926）。
    local rows = ctx.win._rows
    rows[#rows + 1] = el
    return el
end
-- ISTickBox 回呼簽名 (target, index, selected, args)：target＝建構時傳入的 win
local function unifiedOnModTick(target, index, selected, e)
    settingsApply(e, selected)
    -- PlaceNames 開啟會連動強制 Symbols=true（applyToggleOptions 的耦合）：
    -- 重建讓「符號」勾選框立即反映引擎現值，不留 UI/引擎分裂
    if e.id == "PlaceNames" then unifiedRebuild(target) end
end
local function unifiedOnEngineTick(target, index, selected, e)
    unifiedEngineSet(e.id, selected, target._playerNum or 0)
end
-- ISTickBox:new 用法同原設定視窗建法（ISTickBox.lua:282）；單框單選項
local function unifiedAddTick(ctx, x, yy, w, labelText, checked, cb, arg)
    local t = ISTickBox:new(x, yy, w, ctx.fontH + 4, "", ctx.win, cb, arg)
    -- 必須在 addOption「之前」關 keepOnScreen：addOption→setHeight（ISTickBox.lua:234）
    -- 會觸發螢幕夾制，且此刻尚未 addChild、無 parent → getKeepOnScreen() 預設回 true
    -- （ISUIElement.lua:188-193 `not self.parent`）→ 內容 y>螢幕高-高度 的 tick 全被夾到
    -- 同一點（全展開時外觀區四勾選疊字的根因；unifiedAdd 內的補設對此已太遲）。
    t.keepOnScreen = false
    t:initialise()
    t:addOption(labelText)
    t:setSelected(1, checked and true or false)
    return unifiedAdd(ctx, t)
end
local function unifiedOnCombo(target, box, e) settingsApply(e, box.selected) end
-- 下拉列（ISComboBox 建法/回呼同原視窗：ISComboBox.lua:586/253）；
-- 標籤欄寬＝全部 combo 標籤實測最寬（各語系自適應），佔滿目前 lane
local function unifiedAddComboRow(ctx, entry)
    unifiedAdd(ctx, ISLabel:new(ctx.curX, ctx.curY + 3, ctx.fontH, getText(entry.label), 1, 1, 1, 1, UIFont.Small, true))
    local combo = ISComboBox:new(ctx.curX + ctx.comboLabelW + 8, ctx.curY, ctx.laneW - ctx.comboLabelW - 8,
        ctx.fontH + 6, ctx.win, unifiedOnCombo, entry)
    combo:initialise()
    for j = 1, #entry.items do combo:addOption(getText(entry.items[j])) end
    combo.selected = getComboIndex(entry.id, entry.default)
    unifiedAdd(ctx, combo)
    ctx.curY = ctx.curY + ctx.rowH
end
local function unifiedAddBtn(ctx, x, yy, w, labelText, fn, tooltip)
    local b = ISButton:new(x, yy, w, ctx.fontH + 4, labelText, ctx.win, fn)
    b:initialise()
    b.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    if tooltip then b.tooltip = tooltip end
    return unifiedAdd(ctx, b)
end
-- 滑條列：標籤＋ISSliderPanel＋右側數值標（嵌自訂視窗同構用例 ISWorldMap.lua:56）。
-- onValueChange 拖曳中連續觸發：只寫記憶體值（繪製端每幀讀值＝即時預覽），
-- 放開滑鼠才 save 落盤（避免拖曳中高頻檔案 IO）；初值 setCurrentValue 帶
-- ignoreOnChange=true 免建構時誤觸發（ISSliderPanel.lua:181）
-- 滑條數值標文字：0 值可用 zeroLabel 顯示「不限」等字（顯示距離用），其餘走 fmt。
-- cap（伺服器上限）有值時附「/上限」＝玩家直接看到自己還能拉到多少，不必從
-- 軌道長度反推——存值超上限時軌道會讓位（unifiedSliderRange），反推會得到錯的數。
-- test:slider-text:start
local function unifiedSliderText(entry, value, cap)
    local s
    if value == 0 and entry.zeroLabel then
        s = getText(entry.zeroLabel)
    else
        s = string.format(entry.fmt, value)
    end
    if cap then s = s .. "/" .. cap end
    return s
end
-- test:slider-text:end
-- 距離滑條的可拉上限：min(entry.max=2000, 伺服器上限)，但存值更大時以存值為準。
--   · 向下縮到伺服器現值：玩家由可拉範圍看到伺服器允許值（數字另由數值標直出）
--   · 向上讓位給既有存值：ESC 頁是全值域、可寫入較大值，若硬縮 max，玩家在本
--     視窗第一次點擊軌道就會把存值永久截斷（ISSliderPanel 的 setCurrentValue
--     一律夾到 maxValue；Claude review 抓出）。讓位後兩表面顯示一致、不毀偏好，
--     且 displayDist 讀取端仍強制伺服器上限——放寬的只有 UI，不是實際可見範圍。
-- 僅於重建時計算（開窗／展開即刷新），不追蹤視窗開著期間的沙盒變動：與數值標
-- 的 cap 同步刷新，避免數字與軌道長度互相矛盾。
-- test:slider-range:start
local function unifiedSliderRange(entry, cap, stored)
    local maxV = entry.max
    if cap and cap < maxV then maxV = cap end
    if type(stored) == "number" and stored > maxV then maxV = stored end
    return maxV
end
-- test:slider-range:end
local function unifiedAddSliderRows(ctx, list)
    for i = 1, #list do
        local entry = list[i]
        unifiedAdd(ctx, ISLabel:new(ctx.curX, ctx.curY + 3, ctx.fontH, getText(entry.label), 1, 1, 1, 1, UIFont.Small, true))
        -- capBy＝伺服器沙盒距離選項名：cap 供數值標顯示「/上限」，上限經
        -- unifiedSliderRange 動態計算（含全域上限 AllInfoDistance；存值超上限時
        -- 讓位不截斷）。兩者都在重建時現算——開窗/展開即反映現值；視窗開著時
        -- 管理員改沙盒須重開才更新（刻意與軌道長度同步：只更新數字會讓數字與
        -- 軌道互相矛盾），讀取端 displayDist 每幀即時，不會因此放寬實際限制
        local cap
        local maxV = entry.max
        if entry.capBy and sandboxDist then
            cap = sandboxDist(entry.capBy)
            maxV = unifiedSliderRange(entry, cap,
                getSliderValue(entry.id, entry.default, entry.min, entry.max))
        end
        -- 值標欄寬＝本列可能出現的最寬字串（含 zeroLabel 與 /上限 後綴）
        local valW = utw("100%")
        local widest = utw(unifiedSliderText(entry, maxV, cap))
        if widest > valW then valW = widest end
        if entry.zeroLabel then
            local zw = utw(unifiedSliderText(entry, 0, cap))
            if zw > valW then valW = zw end
        end
        valW = valW + 10
        local valLabel = ISLabel:new(ctx.curX + ctx.laneW - valW, ctx.curY + 3, ctx.fontH, "", 1, 1, 1, 1, UIFont.Small, true)
        -- 軌道寬下限（不得 <= 30）：laneW 的 420 上限是硬常數、不隨 PZ「字型大小」
        -- 六檔（16/19/26/33/38/隨視窗）縮放，而 comboLabelW/valW 是縮放後的量測值
        -- ——大字型下相減會逼近 0 甚至倒轉，而 ISSliderPanel 的 sliderBarDim.w
        -- ＝寬-30（左右箭頭），onMouseDown 拿它當除數（ISSliderPanel.lua:55/80）：
        -- 0 會得 nan 並經 setCurrentValue 把 nan 寫進選項落盤 ini。寧可該列右側與
        -- 數值標重疊，也不能讓寬度倒轉——ponytail: 90＝bar 60，夠拖曳即可。
        -- 上游根治是把 420 改成字型相對，但那會連動全視窗八個區塊的欄寬與視窗
        -- 總寬（雙欄），風險高於本次變更本身，留給獨立的版面改版。
        local sliderW = ctx.laneW - ctx.comboLabelW - valW - 14
        if sliderW < 90 then sliderW = 90 end
        local slider = ISSliderPanel:new(ctx.curX + ctx.comboLabelW + 8, ctx.curY + 1,
            sliderW, ctx.fontH + 4, ctx.win,
            function(target, value)
                valLabel:setName(unifiedSliderText(entry, value, cap))
                if not modOptions then return end
                local opt = modOptions:getOption(entry.id)
                if opt then opt:setValue(value) end -- 同步 ESC 頁元件（ModOptions.lua slider setValue）
            end)
        slider:initialise()
        slider.doToolTip = false
        -- setValues 第 5 參 _ignoreCurVal 必須為 true：否則它會拿「建構期初始
        -- currentValue（50）」觸發 onValueChange → 回呼把 50 夾限值寫進選項，
        -- 污染存檔（實測：殭屍/動物大小開窗即變 16/48、透明度變 50——
        -- 原版 MainOptions 沒中是因為它先 setValues 後掛回呼）
        slider:setValues(entry.min, maxV, entry.step, entry.step * 5, true)
        slider:setCurrentValue(getSliderValue(entry.id, entry.default, entry.min, maxV), true)
        -- ⚠ cap 必須與 onValueChange 內同樣傳入：漏傳會讓開窗時顯示「200」、
        -- 動過滑條才變「200/300」（codex review 抓出；守衛見 test_livestock_visibility）
        valLabel:setName(unifiedSliderText(entry, slider:getCurrentValue(), cap))
        -- 放開才落盤（拖曳結束/點軌道/箭頭按鈕皆經 onMouseUp；拖出元件外走 Outside）
        local origUp = slider.onMouseUp
        function slider:onMouseUp(mx, my)
            local r = origUp(self, mx, my)
            if PZAPI and PZAPI.ModOptions then PZAPI.ModOptions:save() end
            return r
        end
        local origUpOutside = slider.onMouseUpOutside
        function slider:onMouseUpOutside(mx, my)
            local r = origUpOutside(self, mx, my)
            if PZAPI and PZAPI.ModOptions then PZAPI.ModOptions:save() end
            return r
        end
        unifiedAdd(ctx, slider)
        unifiedAdd(ctx, valLabel)
        ctx.curY = ctx.curY + ctx.rowH
    end
end

-- ── 各區塊 builder（原 unifiedRebuild 的 if sec.id == ... 分支逐一拆出）──
local function unifiedBuildLayers(ctx)
    local col = 0
    for i = 1, #UNIFIED_LAYER_TICKS do
        local t = UNIFIED_LAYER_TICKS[i]
        if not (t.mpOnly and not isClient()) then
            local checked = t.engine and unifiedEngineGet(t.id, ctx.pn)
                or (not t.engine and getBoolOption(t.id, t.default))
            unifiedAddTick(ctx, ctx.curX + 4 + col * ctx.colW2, ctx.curY, ctx.colW2 - 8,
                getTextOrNull(t.label) or t.id, checked,
                t.engine and unifiedOnEngineTick or unifiedOnModTick, t)
            col = col + 1
            if col == ctx.cols2 then col = 0; ctx.curY = ctx.curY + ctx.rowH end
        end
    end
    if col ~= 0 then ctx.curY = ctx.curY + ctx.rowH end
    -- 註冊的 zone 動作列（如 Zones addon 的「生成範例檔」）：伺服器區域 tick 之後
    -- 渲染 [combo]+[按鈕] 一列（options 有給才有 combo）。無註冊＝零列（dormant）。
    for ai = 1, #registeredZoneActions do
        local action = registeredZoneActions[ai]
        local btnLabel = getText(action.labelKey)
        local btnTip = action.tooltipKey and getText(action.tooltipKey) or nil
        if action.options then
            local btnW = math.max(60, math.min(utw(btnLabel) + 20, ctx.laneW - 130))
            local comboW = ctx.laneW - 6 - btnW - 4
            local combo = ISComboBox:new(ctx.curX + 4, ctx.curY, comboW, ctx.fontH + 6, ctx.win,
                function(target, box) action._selected = box.selected end)
            combo:initialise()
            for j = 1, #action.options do
                combo:addOption(getText(action.options[j].labelKey))
            end
            combo.selected = action._selected or 1
            unifiedAdd(ctx, combo)
            unifiedAddBtn(ctx, ctx.curX + 4 + comboW + 4, ctx.curY, btnW, btnLabel, function()
                local idx = combo.selected or 1
                action._selected = idx
                local opt = action.options[idx]
                action.onTrigger(opt and opt.value)
            end, btnTip)
        else
            unifiedAddBtn(ctx, ctx.curX + 4, ctx.curY, ctx.laneW - 6, btnLabel,
                function() action.onTrigger(nil) end, btnTip)
        end
        ctx.curY = ctx.curY + ctx.rowH
    end
end

local function unifiedBuildPoicat(ctx)
    -- 兩顆母開關（與 ZoneLayer 解耦，只控內部 POI provider）：顯示資源點（圖標）
    -- ＋顯示資源點區塊。同 animals 母開關版面（colW2 雙欄）。
    local poiMasters = {
        { id = "PoiIcons", label = "UI_MinidoracatMiniMap_PoiIcons", default = true },
        { id = "PoiBlocks", label = "UI_MinidoracatMiniMap_PoiBlocks", default = false },
    }
    local mcol = 0
    for i = 1, #poiMasters do
        unifiedAddTick(ctx, ctx.curX + 4 + mcol * ctx.colW2, ctx.curY, ctx.colW2 - 8,
            getTextOrNull(poiMasters[i].label) or poiMasters[i].id,
            getBoolOption(poiMasters[i].id, poiMasters[i].default), unifiedOnModTick, poiMasters[i])
        mcol = mcol + 1
        if mcol == ctx.cols2 then mcol = 0; ctx.curY = ctx.curY + ctx.rowH end
    end
    if mcol ~= 0 then ctx.curY = ctx.curY + ctx.rowH end
    -- 圖標樣式切換（整列，與母開關區分）：勾＝彩色全彩圖標，不勾＝類別色單色剪影。
    unifiedAddTick(ctx, ctx.curX + 4, ctx.curY, ctx.laneW - 6,
        getTextOrNull("UI_MinidoracatMiniMap_PoiColorIcons") or "PoiColorIcons",
        getBoolOption("PoiColorIcons", false), unifiedOnModTick, { id = "PoiColorIcons" })
    ctx.curY = ctx.curY + ctx.rowH
    -- 區塊形狀（整列）：勾＝整棟一框，不勾＝逐房間矩形。只影響區塊模式，
    -- 圖標位置不變（POI provider 於整棟模式帶 iconRect 釘住最大房間）
    unifiedAddTick(ctx, ctx.curX + 4, ctx.curY, ctx.laneW - 6,
        getTextOrNull("UI_MinidoracatMiniMap_PoiWholeBuilding") or "PoiWholeBuilding",
        getBoolOption("PoiWholeBuilding", false), unifiedOnModTick, { id = "PoiWholeBuilding" })
    ctx.curY = ctx.curY + ctx.rowH
    -- 20 類別勾選格（poiCols 欄，短標籤預設 3 欄，欄距 8px）＋全選/全不選。
    -- 每格獨立 Cat_<key> 布林選項；勾選經 settingsApply 落地，POI provider
    -- 下一 tick 由簽章偵測到變動重建（沿 C2）。
    local order = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.ORDER
    local pcats = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.CATEGORIES
    if type(order) == "table" and type(pcats) == "table" then
        local n = #order
        for i = 1, n do
            local key = order[i]
            local def = pcats[key]
            if def then
                local cx = ctx.curX + 4 + ((i - 1) % ctx.poiCols) * ctx.colWpoi
                local cy = ctx.curY + math.floor((i - 1) / ctx.poiCols) * ctx.rowH
                -- 列首類別小圖（捲動面板 render 畫，染該類別 color）＝面板即圖例，
                -- 與地圖上該類 POI 同色；缺圖時 tex=nil，render 跳過、版面不塌（沿動物物種格）
                local col = def.color or { r = 0.92, g = 0.92, b = 0.92 }
                local icons = ctx.win._icons
                icons[#icons + 1] = {
                    tex = adotsTexture and adotsTexture("media/ui/poi_icons/poi_" .. key .. ".png"),
                    x = cx, y = cy, size = ctx.fontH + 2, r = col.r, g = col.g, b = col.b }
                unifiedAddTick(ctx, cx + ctx.fontH + 5, cy, ctx.colWpoi - ctx.fontH - 6, getText(def.nameKey),
                    getBoolOption("Cat_" .. key, true),
                    function(target, index, selected)
                        settingsApply({ id = "Cat_" .. key }, selected)
                    end)
            end
        end
        ctx.curY = ctx.curY + math.ceil(n / ctx.poiCols) * ctx.rowH + 2
        local halfW = math.floor((ctx.laneW - 10) / 2)
        unifiedAddBtn(ctx, ctx.curX + 4, ctx.curY, halfW, getText("UI_MinidoracatMiniMap_SelectAll"), function()
            for i = 1, n do settingsApply({ id = "Cat_" .. order[i] }, true) end
            unifiedRebuild(ctx.win)
        end)
        unifiedAddBtn(ctx, ctx.curX + 4 + halfW + 4, ctx.curY, halfW, getText("UI_MinidoracatMiniMap_SelectNone"), function()
            for i = 1, n do settingsApply({ id = "Cat_" .. order[i] }, false) end
            unifiedRebuild(ctx.win)
        end)
        ctx.curY = ctx.curY + ctx.rowH
    end
    unifiedAddSliderRows(ctx, UNIFIED_SLIDERS.poi)
end

local function unifiedBuildZombie(ctx)
    unifiedAddTick(ctx, ctx.curX + 4, ctx.curY, ctx.laneW - 6, getText("UI_MinidoracatMiniMap_ZombieDots"),
        getBoolOption("ZombieDots", false), unifiedOnModTick, { id = "ZombieDots" })
    ctx.curY = ctx.curY + ctx.rowH
    for i = 1, #UNIFIED_ZOMBIE_COMBOS do unifiedAddComboRow(ctx, UNIFIED_ZOMBIE_COMBOS[i]) end
    unifiedAddSliderRows(ctx, UNIFIED_SLIDERS.zombie)
end

local function unifiedBuildAnimals(ctx)
    local masters = {
        { id = "AnimalWild", label = "UI_MinidoracatMiniMap_AnimalWild" },
        { id = "AnimalLivestock", label = "UI_MinidoracatMiniMap_AnimalLivestock" },
    }
    local col = 0
    for i = 1, #masters do
        unifiedAddTick(ctx, ctx.curX + 4 + col * ctx.colW2, ctx.curY, ctx.colW2 - 8, getText(masters[i].label),
            getBoolOption(masters[i].id, false), unifiedOnModTick, { id = masters[i].id })
        col = col + 1
        if col == ctx.cols2 then col = 0; ctx.curY = ctx.curY + ctx.rowH end
    end
    if col ~= 0 then ctx.curY = ctx.curY + ctx.rowH end
    if ctx.livestockMode == 4 then
        unifiedAdd(ctx, ISLabel:new(ctx.curX + 4, ctx.curY, ctx.fontH,
            getText("UI_MinidoracatMiniMap_LivestockHiddenBySandbox"),
            0.95, 0.55, 0.25, 1, UIFont.Small, true))
        ctx.curY = ctx.curY + ctx.rowH
    end
    -- 物種網格（欄數自適應）：列首小圖（捲動面板 render 畫）＋勾選（勾＝顯示）
    local disOpt = modOptions and modOptions:getOption("AnimalSpeciesFilter")
    local dis = unifiedCsvSet(disOpt and disOpt:getValue() or "")
    for i = 1, #ADOTS_SPECIES_UI do
        local def = ADOTS_SPECIES_UI[i]
        local cx = ctx.curX + 4 + ((i - 1) % ctx.cols3) * ctx.colW3
        local cy = ctx.curY + math.floor((i - 1) / ctx.cols3) * ctx.rowH
        local art = ADOTS_ART and ADOTS_ART[def.groups[1]]
        local icons = ctx.win._icons
        icons[#icons + 1] = { name = art and art.sym, x = cx, y = cy, size = ctx.fontH + 2 }
        unifiedAddTick(ctx, cx + ctx.fontH + 5, cy, ctx.colW3 - ctx.fontH - 6, getText(def.label), not dis[def.key],
            function(target, index, selected, e)
                unifiedSetFilter("AnimalSpeciesFilter", ADOTS_SPECIES_UI, e.key, selected)
            end, def)
    end
    ctx.curY = ctx.curY + math.ceil(#ADOTS_SPECIES_UI / ctx.cols3) * ctx.rowH + 2
    local halfW = math.floor((ctx.laneW - 10) / 2)
    unifiedAddBtn(ctx, ctx.curX + 4, ctx.curY, halfW, getText("UI_MinidoracatMiniMap_SelectAll"), function()
        unifiedSetAllFilter("AnimalSpeciesFilter", ADOTS_SPECIES_UI, true)
        unifiedRebuild(ctx.win)
    end)
    unifiedAddBtn(ctx, ctx.curX + 4 + halfW + 4, ctx.curY, halfW, getText("UI_MinidoracatMiniMap_SelectNone"), function()
        unifiedSetAllFilter("AnimalSpeciesFilter", ADOTS_SPECIES_UI, false)
        unifiedRebuild(ctx.win)
    end)
    ctx.curY = ctx.curY + ctx.rowH
    for i = 1, #UNIFIED_ANIMAL_COMBOS do unifiedAddComboRow(ctx, UNIFIED_ANIMAL_COMBOS[i]) end
    unifiedAddSliderRows(ctx, UNIFIED_SLIDERS.animals)
end

local function unifiedBuildVehicles(ctx)
    unifiedAddTick(ctx, ctx.curX + 4, ctx.curY, ctx.laneW - 6, getText("UI_MinidoracatMiniMap_VehicleDots"),
        getBoolOption("VehicleDots", false), unifiedOnModTick, { id = "VehicleDots" })
    ctx.curY = ctx.curY + ctx.rowH
    local disOpt = modOptions and modOptions:getOption("VehicleCategoryFilter")
    local dis = unifiedCsvSet(disOpt and disOpt:getValue() or "")
    for i = 1, #ADOTS_VEHCAT_UI do
        local def = ADOTS_VEHCAT_UI[i]
        local cx = ctx.curX + 4 + ((i - 1) % ctx.cols2) * ctx.colW2
        local cy = ctx.curY + math.floor((i - 1) / ctx.cols2) * ctx.rowH
        unifiedAddTick(ctx, cx, cy, ctx.colW2 - 8, getText(def.label), not dis[def.key],
            function(target, index, selected, e)
                unifiedSetFilter("VehicleCategoryFilter", ADOTS_VEHCAT_UI, e.key, selected)
            end, def)
    end
    ctx.curY = ctx.curY + math.ceil(#ADOTS_VEHCAT_UI / ctx.cols2) * ctx.rowH
    for i = 1, #UNIFIED_VEHICLE_COMBOS do unifiedAddComboRow(ctx, UNIFIED_VEHICLE_COMBOS[i]) end
    unifiedAddSliderRows(ctx, UNIFIED_SLIDERS.vehicles)
end

local function unifiedBuildWorldmap(ctx)
    local col = 0
    for i = 1, #UNIFIED_WM_TICKS do
        local t = UNIFIED_WM_TICKS[i]
        unifiedAddTick(ctx, ctx.curX + 4 + col * ctx.colW2, ctx.curY, ctx.colW2 - 8, getText(t.label),
            getBoolOption(t.id, false), unifiedOnModTick, { id = t.id })
        col = col + 1
        if col == ctx.cols2 then col = 0; ctx.curY = ctx.curY + ctx.rowH end
    end
    if col ~= 0 then ctx.curY = ctx.curY + ctx.rowH end
    if ctx.livestockMode == 4 then
        unifiedAdd(ctx, ISLabel:new(ctx.curX + 4, ctx.curY, ctx.fontH,
            getText("UI_MinidoracatMiniMap_LivestockHiddenBySandbox"),
            0.95, 0.55, 0.25, 1, UIFont.Small, true))
        ctx.curY = ctx.curY + ctx.rowH
    end
    unifiedAdd(ctx, ISLabel:new(ctx.curX + 4, ctx.curY, ctx.fontH, getText("UI_MinidoracatMiniMap_WMShared"),
        0.62, 0.62, 0.62, 1, UIFont.Small, true))
    ctx.curY = ctx.curY + ctx.rowH
end

local function unifiedBuildAppearance(ctx)
    for i = 1, #UNIFIED_APPEAR_COMBOS do unifiedAddComboRow(ctx, UNIFIED_APPEAR_COMBOS[i]) end
    local col = 0
    for i = 1, #UNIFIED_APPEAR_TICKS do
        local t = UNIFIED_APPEAR_TICKS[i]
        unifiedAddTick(ctx, ctx.curX + 4 + col * ctx.colW2, ctx.curY, ctx.colW2 - 8, getText(t.label),
            getBoolOption(t.id, t.default), unifiedOnModTick, t)
        col = col + 1
        if col == ctx.cols2 then col = 0; ctx.curY = ctx.curY + ctx.rowH end
    end
    if col ~= 0 then ctx.curY = ctx.curY + ctx.rowH end
    unifiedAddSliderRows(ctx, UNIFIED_SLIDERS.appearance) -- 穿透模式地圖不透明度
    -- 恢復預設尺寸：清 CustomSize 回下拉正方形（apply→save 順序同 settingsApply）
    unifiedAddBtn(ctx, ctx.curX + 4, ctx.curY + 2, ctx.laneW - 6, getText("UI_MinidoracatMiniMap_ResetSize"),
        function()
            if not modOptions then return end
            local opt = modOptions:getOption("CustomSize")
            if not opt then return end
            opt:setValue("")
            if modOptions.apply then modOptions:apply() end
            PZAPI.ModOptions:save()
        end, getText("UI_MinidoracatMiniMap_ResetSize_tooltip"))
    ctx.curY = ctx.curY + ctx.rowH + 4
end

-- builder 分派表（骨架見 UNIFIED_SECTIONS）
-- 顯示距離區：說明列＋5 類距離滑條（0＝不限；滑條上限＝伺服器允許範圍）
local function unifiedBuildDistance(ctx)
    unifiedAdd(ctx, ISLabel:new(ctx.curX, ctx.curY + 3, ctx.fontH,
        getText("UI_MinidoracatMiniMap_DistNote"), 0.75, 0.75, 0.75, 1, UIFont.Small, true))
    ctx.curY = ctx.curY + ctx.rowH
    unifiedAddSliderRows(ctx, UNIFIED_SLIDERS.distance)
end
-- 長提示句斷行（ISLabel 無自動換行，長句會溢出 lane——實測「無類別提示」
-- 四語皆超寬）：貪婪斷行，CJK 逐字可斷、拉丁以最後空白優先；UTF-8 逐碼點
-- 步進，絕不切壞多位元組字元。僅設定視窗重建時執行，量測成本無妨
local function unifiedAddWrappedNote(ctx, text)
    local tm = getTextManager()
    local maxW = ctx.laneW - 10
    local s = tostring(text or "")
    local n = #s
    local lineStart = 1
    local lastSpaceEnd = nil -- 行內最後一個空白之後的 byte 位置（拉丁斷點）
    local function emit(seg)
        unifiedAdd(ctx, ISLabel:new(ctx.curX + 4, ctx.curY + 3, ctx.fontH,
            seg, 0.75, 0.75, 0.75, 1, UIFont.Small, true))
        ctx.curY = ctx.curY + ctx.rowH
    end
    local i = 1
    while i <= n do
        local b = string.byte(s, i)
        local cl = (b >= 240 and 4) or (b >= 224 and 3) or (b >= 192 and 2) or 1
        local j = i + cl - 1
        if tm:MeasureStringX(UIFont.Small, string.sub(s, lineStart, j)) > maxW
            and lineStart < i then
            local brk = lastSpaceEnd
            if brk and brk > lineStart then
                emit(string.sub(s, lineStart, brk - 1))
                lineStart = brk
            else
                emit(string.sub(s, lineStart, i - 1))
                lineStart = i
            end
            lastSpaceEnd = nil
            -- 不前進 i：同一字元以新行基準重新量測
        else
            if b == 32 then lastSpaceEnd = j + 1 end
            i = j + 1
        end
    end
    if lineStart <= n then emit(string.sub(s, lineStart, n)) end
end

-- 伺服器區域區（有外部 zone provider 才插入，見上方 OnGameBoot）：名稱遠距開關
-- ＋動態類別勾選。類別是 zones.json 選配欄位——伺服器定義什麼列什麼；MP 區域
-- 非同步到貨，重開視窗即刷新清單。已知取捨：CSV 依「當前可見類別」序列化，
-- 已停用但暫不在清單的類別（伺服器移除該類全部區域期間改勾選）會被序列化丟出
-- ——影響僅「該類別回歸時恢復顯示」，可再手動關
local function unifiedBuildZones(ctx)
    unifiedAddTick(ctx, ctx.curX + 4, ctx.curY, ctx.laneW - 6,
        getTextOrNull("UI_MinidoracatMiniMap_ZoneNamesFar") or "ZoneNamesFar",
        getBoolOption("ZoneNamesFar", true), unifiedOnModTick, { id = "ZoneNamesFar" })
    ctx.curY = ctx.curY + ctx.rowH
    local cats = Core.zoneExternalCategories and Core.zoneExternalCategories() or {}
    if #cats == 0 then
        unifiedAddWrappedNote(ctx, getText("UI_MinidoracatMiniMap_ZoneNoCats"))
        return
    end
    local defs = {}
    for i = 1, #cats do defs[i] = { key = cats[i] } end
    local disOpt = modOptions and modOptions:getOption("ZoneCategoryFilter")
    local dis = unifiedCsvSet(disOpt and disOpt:getValue() or "")
    local col = 0
    for i = 1, #cats do
        local key = cats[i]
        unifiedAddTick(ctx, ctx.curX + 4 + col * ctx.colW2, ctx.curY, ctx.colW2 - 8,
            key, not dis[key],
            function(target, index, selected)
                unifiedSetFilter("ZoneCategoryFilter", defs, key, selected)
            end)
        col = col + 1
        if col == ctx.cols2 then col = 0; ctx.curY = ctx.curY + ctx.rowH end
    end
    if col ~= 0 then ctx.curY = ctx.curY + ctx.rowH end
    ctx.curY = ctx.curY + 2
    local halfW = math.floor((ctx.laneW - 10) / 2)
    unifiedAddBtn(ctx, ctx.curX + 4, ctx.curY, halfW, getText("UI_MinidoracatMiniMap_SelectAll"), function()
        unifiedSetAllFilter("ZoneCategoryFilter", defs, true)
        unifiedRebuild(ctx.win)
    end)
    unifiedAddBtn(ctx, ctx.curX + 8 + halfW, ctx.curY, halfW, getText("UI_MinidoracatMiniMap_SelectNone"), function()
        unifiedSetAllFilter("ZoneCategoryFilter", defs, false)
        unifiedRebuild(ctx.win)
    end)
    ctx.curY = ctx.curY + ctx.rowH + 4
end

local UNIFIED_BUILDERS = {
    layers = unifiedBuildLayers, poicat = unifiedBuildPoicat, zones = unifiedBuildZones,
    zombie = unifiedBuildZombie,
    animals = unifiedBuildAnimals, vehicles = unifiedBuildVehicles, distance = unifiedBuildDistance,
    worldmap = unifiedBuildWorldmap, appearance = unifiedBuildAppearance,
}

-- 版面量測（原 unifiedRebuild 前段拆出）：各語系標籤實測寬度決定 lane 寬與欄數
-- ——CJK/EN 字長差異大，固定欄寬會右緣裁字、兩欄疊字（實測回饋）
local function unifiedMeasureLayout()
    local tm = getTextManager()
    local fontH = tm:getFontHeight(UIFont.Small)
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
        tw(getText("UI_MinidoracatMiniMap_VehicleDots")),
        tw(getText("UI_MinidoracatMiniMap_PoiIcons")),        -- poicat 母開關（現不在 LAYER_TICKS）
        tw(getText("UI_MinidoracatMiniMap_PoiBlocks")))
    for i = 1, #ADOTS_VEHCAT_UI do
        max2 = math.max(max2, tw(getText(ADOTS_VEHCAT_UI[i].label)))
    end
    -- 動態區域類別標籤（zones 區塊插入時才有；長類別名不納量測會跨欄裁切）
    if UNIFIED_LANE.zones and Core.zoneExternalCategories then
        local zcats = Core.zoneExternalCategories()
        for i = 1, #zcats do max2 = math.max(max2, tw(zcats[i])) end
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
    local maxPoi = 0                      -- POI 類別格（列首類別小圖＋勾選＋短標籤，目標 3 欄）
    do
        local po = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.ORDER
        local pc = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.CATEGORIES
        if type(po) == "table" and type(pc) == "table" then
            for i = 1, #po do
                local d = pc[po[i]]
                if d then maxPoi = math.max(maxPoi, tw(getText(d.nameKey))) end
            end
        end
    end
    local needPoi = maxPoi + TICK_W + fontH + 10 -- +fontH+10＝列首小圖寬＋間距（同 need3 動物格）
    local comboLabelW = 0                 -- combo/滑條列標籤欄（同欄寬，混排對齊）
    local comboGroups = { UNIFIED_ZOMBIE_COMBOS, UNIFIED_ANIMAL_COMBOS,
        UNIFIED_VEHICLE_COMBOS, UNIFIED_APPEAR_COMBOS,
        UNIFIED_SLIDERS.zombie, UNIFIED_SLIDERS.animals,
        UNIFIED_SLIDERS.vehicles, UNIFIED_SLIDERS.poi,
        UNIFIED_SLIDERS.appearance,
        UNIFIED_SLIDERS.distance } -- 漏列＝CJK 標籤被滑條軌道壓住（欄寬量測）
    for g = 1, #comboGroups do
        for i = 1, #comboGroups[g] do
            comboLabelW = math.max(comboLabelW, tw(getText(comboGroups[g][i].label)))
        end
    end
    -- lane 寬＝滿足 lane 內最寬需求（2 欄雙倍/3 欄三倍/combo 標籤＋最小下拉 130），
    -- 夾上限後降欄數（2→1、3→2→1）——寧可長高（有捲動兜底），不裁字
    local statusW = tw(getText("UI_MinidoracatMiniMap_LivestockHiddenBySandbox")) + 8
    local laneW = math.max(300, need2 * 2 + 12, need3 * 3 + 12, needPoi * 3 + 12,
        comboLabelW + 130 + 12, statusW)
    if laneW > 420 then laneW = 420 end
    local cols2 = (need2 * 2 + 12 <= laneW) and 2 or 1
    local cols3 = 3
    if need3 * 3 + 12 > laneW then
        cols3 = (need3 * 2 + 12 <= laneW) and 2 or 1
    end
    local poiCols = 3 -- POI 類別格：短標籤預設 3 欄，超寬語系降 2→1（同 cols3 自適應）
    if needPoi * 3 + 12 > laneW then
        poiCols = (needPoi * 2 + 12 <= laneW) and 2 or 1
    end
    return {
        fontH = fontH, rowH = fontH + 8, laneW = laneW, comboLabelW = comboLabelW,
        cols2 = cols2, cols3 = cols3, poiCols = poiCols,
        colW2 = math.floor((laneW - 6) / cols2),
        colW3 = math.floor((laneW - 6) / cols3),
        colWpoi = math.floor((laneW - 6) / poiCols),
    }
end

-- 全清重建：收合/展開/全選類操作直接重建所有列（值變動一律讀現值，免同步邏輯）。
-- v3 版面：雙欄 lane（區塊固定分欄）＋內容捲動容器
-- （高度夾 viewport，永不超出螢幕——先前全展開高於螢幕、底部被切＝疊字/消失根因）
unifiedRebuild = function(win)
    local panel = win._content
    for i = 1, #win._rows do panel:removeChild(win._rows[i]) end
    win._rows = {}
    win._headers = {}
    win._icons = {}
    local pn = win._playerNum or 0 -- 視窗擁有者（分割畫面 P2+ 不能讀寫到 P1）
    local livestockMode = livestockVisibilityMode()
    win._minidoracatLivestockMode = livestockMode
    local pad = 10
    -- 量測＋版面參數（拆出為 unifiedMeasureLayout）→ ctx 供 helpers/builders 共享
    local ctx = unifiedMeasureLayout()
    ctx.win = win
    ctx.panel = panel
    ctx.pn = pn
    ctx.livestockMode = livestockMode
    local laneW, fontH, rowH = ctx.laneW, ctx.fontH, ctx.rowH
    local W = pad * 2 + laneW * 2 + 12 + 14 -- 雙 lane＋中縫＋右側捲軸預留
    win:setWidth(W)
    panel:setWidth(W)
    -- 標題列右側鈕補位：釘選/收合鈕以「建立當下」寬度定位（ISCollapsableWindow.lua:72/83，
    -- anchorRight 對 Lua setWidth 不生效——實測釘選卡在舊寬度處），改寬後手動跟上
    local tbBtn = win.pinButton or win.collapseButton
    local tbH = tbBtn and tbBtn.height or 16
    if win.pinButton then win.pinButton:setX(W - 1 - tbH) end
    if win.collapseButton then win.collapseButton:setX(W - 1 - tbH) end
    -- 雙欄游標：ctx.curX/curY＝目前 lane 的基準 x 與游標 y（helpers/builders 讀寫）；
    -- 座標皆為 panel 內容座標（捲動由 panel 處理）
    local laneX = { pad, pad + laneW + 12 }
    local laneY = { 0, 0 }

    -- 一鍵全展開/全收合（實測回饋）：頂列橫跨兩 lane
    ctx.curX, ctx.curY = laneX[1], 0
    local halfTop = math.floor((W - pad * 2 - 4) / 2)
    unifiedAddBtn(ctx, pad, 0, halfTop, getText("UI_MinidoracatMiniMap_ExpandAll"), function()
        for i = 1, #UNIFIED_SECTIONS do unifiedExpand[UNIFIED_SECTIONS[i].id] = true end
        unifiedRebuild(win)
    end)
    unifiedAddBtn(ctx, pad + halfTop + 4, 0, halfTop, getText("UI_MinidoracatMiniMap_CollapseAll"), function()
        for i = 1, #UNIFIED_SECTIONS do unifiedExpand[UNIFIED_SECTIONS[i].id] = nil end
        unifiedRebuild(win)
    end)
    laneY[1] = rowH + 4
    laneY[2] = rowH + 4

    for s = 1, #UNIFIED_SECTIONS do
        local sec = UNIFIED_SECTIONS[s]
        local expanded = unifiedExpand[sec.id] and true or false
        local cur = UNIFIED_LANE[sec.id] or 1 -- 固定分欄，位置不隨展開狀態變動
        ctx.curX = laneX[cur]
        ctx.curY = laneY[cur]
        -- 標題列＝空字 ISButton（點擊/hover 底），文字由捲動面板 render 畫
        -- （ISButton 標題強制置中，左對齊＋右側摘要只能自畫）
        local hdr = ISButton:new(ctx.curX - 4, ctx.curY, laneW + 8, fontH + 6, "", win,
            function(target, btn)
                unifiedExpand[btn._minidoracatSec] = not unifiedExpand[btn._minidoracatSec]
                unifiedRebuild(win)
            end)
        hdr._minidoracatSec = sec.id
        hdr:initialise()
        hdr.borderColor = { r = 0.35, g = 0.35, b = 0.35, a = 1 }
        hdr.backgroundColor = { r = 1, g = 1, b = 1, a = 0.06 }
        unifiedAdd(ctx, hdr)
        win._headers[#win._headers + 1] = {
            x = ctx.curX + 2, y = ctx.curY + 3, rx = ctx.curX + laneW - 2,
            text = (expanded and "- " or "+ ") .. getText(sec.label),
            sec = sec, -- 摘要由 panel:render 每幀現算（見 unifiedHeaderSummary）
        }
        ctx.curY = ctx.curY + fontH + 10
        if expanded then
            if sec.gate and sandboxGate(sec.gate, true) == false then
                unifiedAdd(ctx, ISLabel:new(ctx.curX + 4, ctx.curY, fontH,
                    getText("UI_MinidoracatMiniMap_ServerDisabled"),
                    0.95, 0.55, 0.25, 1, UIFont.Small, true))
                ctx.curY = ctx.curY + rowH
            end
            local builder = UNIFIED_BUILDERS[sec.id]
            if builder then builder(ctx) end
        end
        laneY[cur] = ctx.curY + 6
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
    -- 必須先 instantiate 再 setScrollChildren：後者在 javaObject 尚未建立時「靜默 no-op」
    -- （ISUIElement.lua:1647-1649 直接 return）——旗標沒落到 java 端＝子元件渲染不吃
    -- panel 捲動位移（UIElement.java:918-926 getAbsoluteY 的 scrollChildren 分支），
    -- 症狀為勾選/下拉/按鈕固定不動、只有自畫標題/圖標（手動 +getYScroll）會捲。
    panel:instantiate()
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
    -- 掛 prerender 會被 hover 蓋掉，實測回饋）；且在 stencil 內＝跟內容一起裁切。
    -- 直繪「勿」手動加 getYScroll：DrawText/DrawTexture 於 java 端已自加 this.yScroll
    -- （UIElement.java:190-194/331-334），再加一次＝2× 速度、與子元件錯位；
    -- 視窗收合時 panel 不繪＝無穿透
    function panel:render()
        ISPanel.render(self)
        local w = self.parent
        local tm = getTextManager()
        for i = 1, #w._headers do
            local h = w._headers[i]
            self:drawText(h.text, h.x, h.y, 0.92, 0.72, 0.25, 1, UIFont.Small)
            local right = h.sec and unifiedHeaderSummary(h.sec, w._playerNum or 0)
            if right then
                local tww = tm:MeasureStringX(UIFont.Small, right)
                self:drawText(right, h.rx - tww, h.y, 0.62, 0.62, 0.62, 1, UIFont.Small)
            end
        end
        for i = 1, #w._icons do
            local ic = w._icons[i]
            -- tex 預解（POI 類別格）或以 name 惰解（動物物種）；tint 缺省近白（沿動物）
            local tex = ic.tex or (ic.name and adotsTexture and adotsTexture(ic.name))
            if tex then
                self:drawTextureScaled(tex, ic.x, ic.y + 1, ic.size, ic.size, 1,
                    ic.r or 0.92, ic.g or 0.92, ic.b or 0.92)
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

local function toggleSettingsWindow(outer)
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
-- 主檔開窗入口（小地圖齒輪 onButton4 wrap／世界地圖爪印鈕）呼叫時查表＋nil 防呆
Core.toggleSettingsWindow = toggleSettingsWindow
