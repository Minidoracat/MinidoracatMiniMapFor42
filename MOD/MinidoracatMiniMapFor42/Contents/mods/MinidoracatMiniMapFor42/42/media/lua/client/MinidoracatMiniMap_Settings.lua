-- MinidoracatMiniMap_Settings.lua
-- 本檔範圍：地圖顯示設定視窗——builder 資料表、addon-conditional 選項、
-- settingsApply 管線、篩選寫入、搜尋索引、responsive 導覽/inspector 與視窗生命週期。
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
-- 管理員檢視政策 facade（shared/_Policy.lua，主檔載入期快照）。nil＝舊版共用檔
-- 或載入失敗：整組管理員檢視不存在（fail-closed），既有設定照常運作
local Policy = Core.policy

--------------------------------------------------------------------------------
-- 地圖顯示設定（免跑 ESC 選項頁）：分類導覽＋單一 inspector；搜尋非空時
-- inspector 改列跨分類結果。原設定視窗與圖層面板注入項仍走相同 apply helper。
-- 視窗以 ISCollapsableWindow 頂層呈現（標題拖曳＋關閉鈕內建，
-- ISCollapsableWindow.lua:26-61），改值即寫回 ModOptions（同步 ESC 頁元件，
-- ModOptions.lua:68-73）並走既有 modOptions:apply()——尺寸重建/開關即時/
-- 透明度一條龍，不另寫套用邏輯。分類切換/搜尋/全選採「全清重建」模式
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
    { id = "NavRoute", label = "UI_MinidoracatMiniMap_NavRoute", default = true },
    -- Safehouses 移入獨立「安全屋」區塊（safehouse）；PoiIcons/PoiBlocks 移入獨立
    -- 「資源點」區塊（poicat），與 ZoneLayer 解耦
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
        -- 安全屋兩條距離滑條在「安全屋」區塊（UNIFIED_SLIDERS.safehouse），不在此列
        { id = "ClientPoiDisplayDistance", label = "UI_MinidoracatMiniMap_DistPoi",
            default = 0, min = 0, max = 2000, step = 1, fmt = "%d",
            zeroLabel = "UI_MinidoracatMiniMap_DistUnlimited", capBy = "PoiDisplayDistance" },
    },
    -- 安全屋：範圍框／圖標共用 SafehouseDisplayDistance，名稱獨立 SafehouseNameDistance
    safehouse = {
        { id = "ClientSafehouseDisplayDistance", label = "UI_MinidoracatMiniMap_DistSafehouse",
            default = 0, min = 0, max = 2000, step = 1, fmt = "%d",
            zeroLabel = "UI_MinidoracatMiniMap_DistUnlimited", capBy = "SafehouseDisplayDistance" },
        { id = "ClientSafehouseNameDistance", label = "UI_MinidoracatMiniMap_DistSafehouseName",
            default = 0, min = 0, max = 2000, step = 1, fmt = "%d",
            zeroLabel = "UI_MinidoracatMiniMap_DistUnlimited", capBy = "SafehouseNameDistance" },
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
local POI_MASTER_TICKS = {
    { id = "PoiIcons", label = "UI_MinidoracatMiniMap_PoiIcons", default = true },
    { id = "PoiBlocks", label = "UI_MinidoracatMiniMap_PoiBlocks", default = false },
}
local ANIMAL_MASTER_TICKS = {
    { id = "AnimalWild", label = "UI_MinidoracatMiniMap_AnimalWild", default = false },
    { id = "AnimalLivestock", label = "UI_MinidoracatMiniMap_AnimalLivestock", default = false },
}
local ANIMAL_NAV_MASTER = {
    label = "UI_MinidoracatMiniMap_SecAnimals",
    members = ANIMAL_MASTER_TICKS,
}
local ZOMBIE_MASTER = {
    id = "ZombieDots", label = "UI_MinidoracatMiniMap_ZombieDots", default = false,
}
local VEHICLE_MASTER = {
    id = "VehicleDots", label = "UI_MinidoracatMiniMap_VehicleDots", default = false,
}
local ZONE_MASTER = {
    id = "ZoneLayer", label = "UI_MinidoracatMiniMap_ZoneLayer", default = true,
}
-- 安全屋三件套（範圍框／圖標／名稱）：導覽 pill 投影三者 OR（同動物母開關）
local SAFEHOUSE_MASTER_TICKS = {
    { id = "Safehouses", label = "UI_MinidoracatMiniMap_Safehouses", default = true },
    { id = "SafehouseIcons", label = "UI_MinidoracatMiniMap_SafehouseIcons", default = true },
    { id = "SafehouseNames", label = "UI_MinidoracatMiniMap_SafehouseNames", default = true },
}
local SAFEHOUSE_NAV_MASTER = {
    label = "UI_MinidoracatMiniMap_SecSafehouse",
    members = SAFEHOUSE_MASTER_TICKS,
}

-- 分類骨架：studioBuildInspector 依 id 分派 builder；gate＝伺服器沙盒閘
local UNIFIED_SECTIONS = {
    { id = "layers", label = "UI_MinidoracatMiniMap_SecLayers", icon = "layers" },
    { id = "poicat", label = "UI_MinidoracatMiniMap_SecPOI",
        icon = "pin", master = POI_MASTER_TICKS[1] },
    { id = "safehouse", label = "UI_MinidoracatMiniMap_SecSafehouse",
        master = SAFEHOUSE_NAV_MASTER },
    { id = "distance", label = "UI_MinidoracatMiniMap_SecDistance", icon = "gauge" },
    { id = "zombie", label = "UI_MinidoracatMiniMap_SecZombie",
        gate = "AllowZombieDots", master = ZOMBIE_MASTER },
    { id = "animals", label = "UI_MinidoracatMiniMap_SecAnimals",
        gate = "AllowAnimalDots", master = ANIMAL_NAV_MASTER },
    { id = "vehicles", label = "UI_MinidoracatMiniMap_SecVehicles",
        gate = "AllowVehicleDots", master = VEHICLE_MASTER },
    { id = "worldmap", label = "UI_MinidoracatMiniMap_SecWorldMap", icon = "globe" },
    { id = "appearance", label = "UI_MinidoracatMiniMap_SecAppearance", icon = "sliders" },
    { id = "perf", label = "UI_MinidoracatMiniMap_SecPerf", icon = "gauge" },
}

-- 「管理員檢視」分類：三把鑰匙的第三把（玩家自己的本機旗標）唯一的操作面。
-- 分類本身也是三選一才存在——Policy 缺席、玩家沒有 CanSeeAll、或伺服器沒開
-- 戰術政策時整個分類不出現：不合格的玩家連「有這個東西」都不該看到。
-- 刻意不在 OnGameBoot 一次性插入：三個條件全是 live 值（政策可即時改、權限
-- 可被升降、分割畫面每個 slot 各自判定），一次性插入會把首幀狀態凍住。
-- test:settings-studio-admin:start
local ADMIN_SECTION = { id = "admin", label = "UI_MinidoracatMiniMap_SecAdmin", icon = "sliders" }

local function adminSectionEligible(pn)
    if not Policy then return false end
    if Policy.hasCanSeeAll(pn) ~= true then return false end
    return Policy.readBool("AllowAdminTacticalView", false) == true
end

-- 依資格把 ADMIN_SECTION 插在 perf 之前／自 UNIFIED_SECTIONS 移除；回 true＝
-- 成員有變（呼叫端要重建搜尋索引，否則索引留著已消失分類的 hit）。成員比對用
-- table identity 而非 id 字串：addon 分類的 id 由第三方帶入，字串比對會認錯。
local function adminSectionSync(pn)
    local at
    for i = 1, #UNIFIED_SECTIONS do
        if UNIFIED_SECTIONS[i] == ADMIN_SECTION then at = i; break end
    end
    if adminSectionEligible(pn) then
        if at then return false end
        local insertAt = #UNIFIED_SECTIONS + 1
        for i = 1, #UNIFIED_SECTIONS do
            if UNIFIED_SECTIONS[i].id == "perf" then insertAt = i; break end
        end
        table.insert(UNIFIED_SECTIONS, insertAt, ADMIN_SECTION)
        return true
    end
    if not at then return false end
    table.remove(UNIFIED_SECTIONS, at)
    return true
end
-- test:settings-studio-admin:end

local settingsUI -- 單例；獨立頂層視窗，不隨小地圖 Recreate 消失（apply 自行重抓 mm）
-- Addon client 設定區：addon 註冊純資料＋get/set callbacks；值仍由 addon 自己保存。
local addonSettingsById = {}

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
    local MAPB_COLOR_ITEMS = { "UI_MinidoracatMiniMap_MBColor_Green", -- 順序須同 MAPB_COLORS
        "UI_MinidoracatMiniMap_MBColor_Cyan", "UI_MinidoracatMiniMap_MBColor_Yellow",
        "UI_MinidoracatMiniMap_MBColor_Purple", "UI_MinidoracatMiniMap_MBColor_White" }
    -- 框線透明度：三檔沿用小地圖 Opacity 的翻譯鍵與語意；順序須同 MAPB_ALPHAS
    local MAPB_ALPHA_ITEMS = { "UI_MinidoracatMiniMap_Opacity_Full",
        "UI_MinidoracatMiniMap_Opacity_Half", "UI_MinidoracatMiniMap_Opacity_Faint" }
    local mbColor = modOptions:addComboBox("MapBoundsColor", "UI_MinidoracatMiniMap_MapBoundsColor")
    for i = 1, #MAPB_COLOR_ITEMS do mbColor:addItem(MAPB_COLOR_ITEMS[i], i == 1) end
    local mbAlpha = modOptions:addComboBox("MapBoundsAlpha", "UI_MinidoracatMiniMap_MapBoundsAlpha")
    for i = 1, #MAPB_ALPHA_ITEMS do mbAlpha:addItem(MAPB_ALPHA_ITEMS[i], i == 1) end
    -- 統一視窗同步加項：圖層區兩顆勾選＋外觀區框線顏色/透明度下拉（items 與
    -- ESC 頁 addItem 共用同一份表，雙源自此收斂）
    table.insert(UNIFIED_LAYER_TICKS, { id = "MapPackLayers",
        label = "UI_MinidoracatMiniMap_MapPackLayers", default = true })
    table.insert(UNIFIED_LAYER_TICKS, { id = "MapBounds",
        label = "UI_MinidoracatMiniMap_MapBounds", default = true })
    table.insert(UNIFIED_APPEAR_COMBOS, { id = "MapBoundsColor",
        label = "UI_MinidoracatMiniMap_MapBoundsColor", default = 1, items = MAPB_COLOR_ITEMS })
    table.insert(UNIFIED_APPEAR_COMBOS, { id = "MapBoundsAlpha",
        label = "UI_MinidoracatMiniMap_MapBoundsAlpha", default = 1, items = MAPB_ALPHA_ITEMS })
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
    -- per-provider 母開關（provider 註冊時給了 optionLabelKey 才有）：ModOptions 選項
    -- 本體＋統一視窗圖層區加項。渲染時 drawZoneFill/Lines/Icons 依 optionKey 讀值，
    -- 關＝整個 provider 跳過（與 ZoneLayer 總開關 AND）。家族 Zones addon 自 0.5.0
    -- 起不傳（與總開關重複）；機制留給第三方 addon——勿依 provider 數動態隱藏
    -- （雙向幽靈，見主檔 registerZoneProvider 契約註解）
    for i = 1, #registeredZoneProviders do
        local p = registeredZoneProviders[i]
        if p.optionKey then
            modOptions:addTickBox(p.optionKey, p.optionLabelKey, true)
            table.insert(UNIFIED_LAYER_TICKS, { id = p.optionKey,
                label = p.optionLabelKey, default = true })
        end
    end
    -- 自訂區域專屬設定（同本條件：有外部 provider 才出現）——
    -- 名稱遠距開關＋類別篩選 CSV（統一視窗類別勾選自動寫入；空/'-'＝全開）。
    -- 地圖顯示設定的「自訂區域」分類亦在此動態插入（資源點之後、導覽第 3 項）
    modOptions:addTickBox("ZoneNames", "UI_MinidoracatMiniMap_ZoneNames", true,
        "UI_MinidoracatMiniMap_ZoneNames_tooltip")
    modOptions:addTickBox("ZoneNamesFar", "UI_MinidoracatMiniMap_ZoneNamesFar", true,
        "UI_MinidoracatMiniMap_ZoneNamesFar_tooltip")
    modOptions:addTextEntry("ZoneCategoryFilter", "UI_MinidoracatMiniMap_ZoneCategoryFilter", "",
        "UI_MinidoracatMiniMap_ZoneCategoryFilter_tooltip")
    -- 自訂區域顯示距離（僅裁外部 provider；渲染端消費見主檔 distGateParams）：
    -- ESC 頁滑條尾端追加（家規：addon 條件選項一律 OnGameBoot 尾端，同 MapPackLayers
    -- ——PZAPI 無中插 API），前置 addTitle 復用「顯示距離」標題鍵帶出「0＝不限」
    -- 語意（slider 型別 MainOptions 不渲染 tooltip，MainOptions.lua:3024-3027 無
    -- tooltip 讀取——tickbox 才有）；統一視窗走 UNIFIED_SLIDERS.distance 第 6 條
    -- （capBy＝沙盒 ZoneDisplayDistance，含全域上限 AllInfoDistance；zeroLabel＝不限）
    modOptions:addTitle("UI_MinidoracatMiniMap_SecDistanceEsc")
    modOptions:addSlider("ClientZoneDisplayDistance", "UI_MinidoracatMiniMap_DistZone", 0, 2000, 1, 0)
    -- 收尾分隔線（主檔 ESC 距離群組同款規範）：addTitle 只畫標題不畫群組結束，
    -- 本 handler 目前是最後註冊的 OnGameBoot，但再加第三個 addon 條件 handler 時
    -- 其選項會被視覺歸進「顯示距離」標題底下（claude lane review）
    modOptions:addSeparator()
    table.insert(UNIFIED_SLIDERS.distance, { id = "ClientZoneDisplayDistance",
        label = "UI_MinidoracatMiniMap_DistZone", default = 0, min = 0, max = 2000,
        step = 1, fmt = "%d", zeroLabel = "UI_MinidoracatMiniMap_DistUnlimited",
        capBy = "ZoneDisplayDistance" })
    table.insert(UNIFIED_SECTIONS, 3, { id = "zones",
        label = "UI_MinidoracatMiniMap_SecZones", icon = "pin", master = ZONE_MASTER })
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
    if settingsUI and settingsUI:isVisible() then
        for i = 1, #settingsUI._pills do
            local pill = settingsUI._pills[i]
            if pill.entry.id == entry.id then pill.on = value == true end
        end
    end
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


--------------------------------------------------------------------------------
-- 地圖顯示設定拆分：量測（unifiedMeasureLayout）＋通用列 helpers（unifiedAdd*）
-- ＋各分類 builder（unifiedBuild*）各自享有 Kahlua 200 locvar 額度；
-- studioBuildInspector 負責 builder 分派，unifiedRebuild 只決定 pane 與組裝。
-- ctx＝單次重建的共享狀態：win/panel/pn/量測結果與 curX/curY 游標
-- （builder 讀寫 curY，座標皆為 panel 內容座標，捲動由 panel 處理）。
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
    -- PlaceNames 會連動 Symbols；動物兩母項則共同投影成左欄 group pill。
    if e.id == "PlaceNames" or e.id == "AnimalWild" or e.id == "AnimalLivestock" then
        unifiedRebuild(target)
    end
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

-- test:addon-settings-callbacks:start
local function addonRead(fn, default, pn)
    if type(fn) ~= "function" then return default end
    local ok, value = pcall(fn, pn)
    if not ok then return default end
    return value
end

local function addonActionEnabled(entry, pn)
    if entry.enabled == nil then return true end
    local ok, value = pcall(entry.enabled, pn)
    return ok and value ~= false
end

local function addonErrorText(err)
    local kind = type(err)
    if kind == "string" then return err end
    if kind == "number" or kind == "boolean" or kind == "nil" then
        return tostring(err)
    end
    return "<non-scalar addon error>"
end

-- addon setter 一律隔離：第三方 set 拋錯只留診斷，不得炸掉設定窗的事件迴圈。
local function addonWrite(entry, value)
    if type(entry.set) ~= "function" then return end
    local ok, err = pcall(entry.set, value)
    if not ok then print("[MinidoracatMiniMap] addon setting failed: " .. addonErrorText(err)) end
end

local function unifiedOnAddonTick(target, index, selected, entry)
    addonWrite(entry, selected == true)
end

local function unifiedOnAddonCombo(target, combo, entry)
    addonWrite(entry, combo.selected)
end

-- action 按鈕：把視窗擁有者 pn 交給 run/enabled；enabled 回 false 不跑；
-- run 拋錯只留一則診斷，不得炸掉設定窗。
local function unifiedOnAddonAction(target, button)
    local entry = button._addonAction
    if type(entry) ~= "table" or type(entry.run) ~= "function" then return end
    local pn = target._playerNum or 0
    if not addonActionEnabled(entry, pn) then return end
    local ok, err = pcall(entry.run, pn)
    if not ok then print("[MinidoracatMiniMap] addon action failed: " .. addonErrorText(err)) end
end
-- test:addon-settings-callbacks:end
local function unifiedAddBtn(ctx, x, yy, w, labelText, fn, tooltip)
    local b = ISButton:new(x, yy, w, ctx.fontH + 4, labelText, ctx.win, fn)
    b:initialise()
    -- 家族皮膚化：淡框淡底、hover 亮階走原生 fade 混色（ISButton:prerender
    -- :117-133 於 backgroundColor↔backgroundColorMouseOver 間補間，守衛
    -- shouldDrawBackground/shouldDrawBorder :91-100；mouseOver 欄位 :12/:19）
    b.borderColor = { r = 0.55, g = 0.55, b = 0.55, a = 0.35 }
    b.backgroundColor = { r = 1, g = 1, b = 1, a = 0.05 }
    b.backgroundColorMouseOver = { r = 1, g = 1, b = 1, a = 0.16 }
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
-- 僅於重建時計算（開窗／切換分類／搜尋或結構刷新），不追蹤視窗開著期間的
-- 沙盒變動；與數值標的 cap 同步刷新，避免數字與軌道長度互相矛盾。
-- test:slider-range:start
local function unifiedSliderRange(entry, cap, stored)
    local maxV = entry.max
    if cap and cap < maxV then maxV = cap end
    if type(stored) == "number" and stored > maxV then maxV = stored end
    return maxV
end
-- test:slider-range:end
-- test:settings-studio-slider:start
local function studioSliderRatio(value, minValue, maxValue)
    if type(value) ~= "number" or value ~= value or maxValue <= minValue then return 0 end
    local ratio = (value - minValue) / (maxValue - minValue)
    if ratio < 0 then return 0 elseif ratio > 1 then return 1 end
    return ratio
end
-- test:settings-studio-slider:end
-- 保留 ISSliderPanel 的 mouse/joypad/value 邏輯，只換 render（原版 render：
-- RadioCom/ISUIRadio/ISSliderPanel.lua:137-158；互動：:38-130/:181-192）。
local function unifiedSliderRender(self)
    ISPanel.render(self)
    local dim = self.sliderBarDim
    if not dim or self.maxValue <= self.minValue then return end
    local ratio = studioSliderRatio(self.currentValue, self.minValue, self.maxValue)
    local Skin = Core.Skin
    local scale = self.disabled and 0.4 or 1
    local painted = Skin and Skin.slider
        and Skin.slider(self, dim.x, 0, dim.w, self.height, ratio, nil, scale)
    if not painted then
        local trackY = math.floor(self.height / 2) - 2
        local fillW = math.floor(dim.w * ratio + 0.5)
        self:drawRect(dim.x, trackY, dim.w, 4, 0.35 * scale, 1, 1, 1)
        self:drawRect(dim.x, trackY, fillW, 4, 0.85 * scale, 1, 0.85, 0.4)
        local knobX = dim.x + fillW - 6
        self:drawRect(knobX, math.floor((self.height - 12) / 2), 12, 12,
            scale, 0.9, 0.9, 0.9)
    end
    if self.doButtons then
        local colors = Skin and Skin.COLORS
        local muted = colors and colors.TEXT_MUTED
        local accent = colors and colors.ACCENT_AMBER
        local left = self.leftPressed and accent or muted
        local right = self.rightPressed and accent or muted
        local textY = math.floor((self.height - getTextManager():getFontHeight(UIFont.Small)) / 2)
        self:drawTextCentre("-", self.btnLeftDim.x + self.btnLeftDim.w / 2, textY,
            left and left.r or 0.62, left and left.g or 0.62, left and left.b or 0.62,
            scale, UIFont.Small)
        self:drawTextCentre("+", self.btnRightDim.x + self.btnRightDim.w / 2, textY,
            right and right.r or 0.62, right and right.g or 0.62, right and right.b or 0.62,
            scale, UIFont.Small)
    end
    if self.joypadFocused then
        self:drawRectBorder(0, 0, self.width, self.height, 0.55, 1, 0.85, 0.4)
    end
end

local function unifiedAddSliderRows(ctx, list)
    for i = 1, #list do
        local entry = list[i]
        unifiedAdd(ctx, ISLabel:new(ctx.curX, ctx.curY + 3, ctx.fontH, getText(entry.label), 1, 1, 1, 1, UIFont.Small, true))
        -- capBy＝伺服器沙盒距離選項名：cap 供數值標顯示「/上限」，上限經
        -- unifiedSliderRange 動態計算（含全域上限 AllInfoDistance；存值超上限時
        -- 讓位不截斷）。兩者都在重建時現算——開窗／分類切換即反映現值；
        -- 視窗開著時管理員改沙盒須觸發結構刷新或重開（刻意與軌道長度同步：
        -- 只更新數字會讓數字與軌道互相矛盾），讀取端 displayDist 每幀即時
        local cap
        local maxV = entry.max
        if entry.capBy and sandboxDist then
            cap = sandboxDist(entry.capBy, ctx.pn)
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
        -- ISSliderPanel 的 sliderBarDim.w＝元件寬-30（左右箭頭），onMouseDown
        -- 拿它當除數（ISSliderPanel.lua:55/80）：極小 viewport 或極長翻譯把列寬
        -- 壓到 30 以下時會得 nan，並經 setCurrentValue 寫進 ini。地圖顯示設定已
        -- 依字型實測需求在不足時切單 pane，這裡仍保留 90px 最終資料安全防線
        -- （有效 bar 60px）；寧可個別極端語系列變擠，也不准產生 nan。
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
        slider.render = unifiedSliderRender
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

-- colW2 雙欄網格骨架（六個 builder 共用）：add(i, x, y, w) 建格；回 false＝跳過不佔格
local function unifiedAddTickCols(ctx, n, add)
    local col = 0
    for i = 1, n do
        if add(i, ctx.curX + 4 + col * ctx.colW2, ctx.curY, ctx.colW2 - 8) ~= false then
            col = col + 1
            if col == ctx.cols2 then col = 0; ctx.curY = ctx.curY + ctx.rowH end
        end
    end
    if col ~= 0 then ctx.curY = ctx.curY + ctx.rowH end
end

-- 全選／全不選按鈕列（poicat/animals/zones 三處同版面）
local function unifiedAddSelectAllNone(ctx, onAll, onNone)
    local halfW = math.floor((ctx.laneW - 10) / 2)
    unifiedAddBtn(ctx, ctx.curX + 4, ctx.curY, halfW,
        getText("UI_MinidoracatMiniMap_SelectAll"), onAll)
    unifiedAddBtn(ctx, ctx.curX + 4 + halfW + 4, ctx.curY, halfW,
        getText("UI_MinidoracatMiniMap_SelectNone"), onNone)
    ctx.curY = ctx.curY + ctx.rowH
end

-- ── 各區塊 builder（原 unifiedRebuild 的 if sec.id == ... 分支逐一拆出）──
local function unifiedBuildLayers(ctx)
    unifiedAddTickCols(ctx, #UNIFIED_LAYER_TICKS, function(i, x, y, w)
        local t = UNIFIED_LAYER_TICKS[i]
        if t.mpOnly and not isClient() then return false end
        local checked = t.engine and unifiedEngineGet(t.id, ctx.pn)
            or (not t.engine and getBoolOption(t.id, t.default))
        unifiedAddTick(ctx, x, y, w, getTextOrNull(t.label) or t.id, checked,
            t.engine and unifiedOnEngineTick or unifiedOnModTick, t)
    end)
end

local function unifiedBuildPoicat(ctx)
    -- 兩顆母開關（與 ZoneLayer 解耦，只控內部 POI provider）：顯示資源點（圖標）
    -- ＋顯示資源點區塊。同 animals 母開關版面（colW2 雙欄）。
    unifiedAddTickCols(ctx, #POI_MASTER_TICKS, function(i, x, y, w)
        local master = POI_MASTER_TICKS[i]
        unifiedAddTick(ctx, x, y, w, getTextOrNull(master.label) or master.id,
            getBoolOption(master.id, master.default), unifiedOnModTick, master)
    end)
    -- 圖標樣式切換（整列，與母開關區分）：勾＝彩色全彩圖標，不勾＝類別色單色剪影。
    unifiedAddTick(ctx, ctx.curX + 4, ctx.curY, ctx.laneW - 6,
        getTextOrNull("UI_MinidoracatMiniMap_PoiColorIcons") or "PoiColorIcons",
        getBoolOption("PoiColorIcons", false), unifiedOnModTick, { id = "PoiColorIcons" })
    ctx.curY = ctx.curY + ctx.rowH
    -- 區塊形狀（整列）：勾＝整棟一框，不勾＝逐房間矩形。只影響區塊模式，
    -- 圖標位置不變（POI provider 於整棟模式帶 iconRect 釘住最大房間）
    unifiedAddTick(ctx, ctx.curX + 4, ctx.curY, ctx.laneW - 6,
        getTextOrNull("UI_MinidoracatMiniMap_PoiWholeBuilding") or "PoiWholeBuilding",
        getBoolOption("PoiWholeBuilding", true), unifiedOnModTick, { id = "PoiWholeBuilding" })
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
                    panel = ctx.panel,
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
        unifiedAddSelectAllNone(ctx, function()
            for i = 1, n do settingsApply({ id = "Cat_" .. order[i] }, true) end
            unifiedRebuild(ctx.win)
        end, function()
            for i = 1, n do settingsApply({ id = "Cat_" .. order[i] }, false) end
            unifiedRebuild(ctx.win)
        end)
    end
    unifiedAddSliderRows(ctx, UNIFIED_SLIDERS.poi)
end

-- 安全屋：三顆開關（雙欄）＋沙盒模式「關閉」時停用對應開關並提示（同牲畜模式 4 提示）
-- ＋兩條距離滑條。模式由 _Safehouse.lua 匯出（呼叫時查 Core.*；模組缺席視為全部）
local function unifiedBuildSafehouse(ctx)
    local rectMode = Core.safehouseDisplayMode and Core.safehouseDisplayMode(ctx.pn) or 3
    local nameMode = Core.safehouseNameMode and Core.safehouseNameMode(ctx.pn) or 3
    unifiedAddTickCols(ctx, #SAFEHOUSE_MASTER_TICKS, function(i, x, y, w)
        local master = SAFEHOUSE_MASTER_TICKS[i]
        local tick = unifiedAddTick(ctx, x, y, w, getText(master.label),
            getBoolOption(master.id, master.default), unifiedOnModTick, master)
        local mode = master.id == "SafehouseNames" and nameMode or rectMode
        tick.enable = mode ~= 1
    end)
    if rectMode == 1 or nameMode == 1 then
        unifiedAdd(ctx, ISLabel:new(ctx.curX + 4, ctx.curY, ctx.fontH,
            getText(rectMode == 1 and "UI_MinidoracatMiniMap_SafehouseHiddenBySandbox"
                or "UI_MinidoracatMiniMap_SafehouseNamesHiddenBySandbox"),
            0.95, 0.55, 0.25, 1, UIFont.Small, true))
        ctx.curY = ctx.curY + ctx.rowH
    end
    unifiedAddSliderRows(ctx, UNIFIED_SLIDERS.safehouse)
end

local function unifiedBuildZombie(ctx)
    for i = 1, #UNIFIED_ZOMBIE_COMBOS do unifiedAddComboRow(ctx, UNIFIED_ZOMBIE_COMBOS[i]) end
    unifiedAddSliderRows(ctx, UNIFIED_SLIDERS.zombie)
end

local function unifiedBuildAnimals(ctx)
    unifiedAddTickCols(ctx, #ANIMAL_MASTER_TICKS, function(i, x, y, w)
        local master = ANIMAL_MASTER_TICKS[i]
        local tick = unifiedAddTick(ctx, x, y, w, getText(master.label),
            getBoolOption(master.id, master.default), unifiedOnModTick, master)
        tick.enable = sandboxGate("AllowAnimalDots", true, ctx.pn) ~= false
            and (master.id ~= "AnimalLivestock" or ctx.livestockMode ~= 4)
    end)
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
        icons[#icons + 1] = { panel = ctx.panel,
            name = art and art.sym, x = cx, y = cy, size = ctx.fontH + 2 }
        unifiedAddTick(ctx, cx + ctx.fontH + 5, cy, ctx.colW3 - ctx.fontH - 6, getText(def.label), not dis[def.key],
            function(target, index, selected, e)
                unifiedSetFilter("AnimalSpeciesFilter", ADOTS_SPECIES_UI, e.key, selected)
            end, def)
    end
    ctx.curY = ctx.curY + math.ceil(#ADOTS_SPECIES_UI / ctx.cols3) * ctx.rowH + 2
    unifiedAddSelectAllNone(ctx, function()
        unifiedSetAllFilter("AnimalSpeciesFilter", ADOTS_SPECIES_UI, true)
        unifiedRebuild(ctx.win)
    end, function()
        unifiedSetAllFilter("AnimalSpeciesFilter", ADOTS_SPECIES_UI, false)
        unifiedRebuild(ctx.win)
    end)
    for i = 1, #UNIFIED_ANIMAL_COMBOS do unifiedAddComboRow(ctx, UNIFIED_ANIMAL_COMBOS[i]) end
    unifiedAddSliderRows(ctx, UNIFIED_SLIDERS.animals)
end

local function unifiedBuildVehicles(ctx)
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
    unifiedAddTickCols(ctx, #UNIFIED_WM_TICKS, function(i, x, y, w)
        local t = UNIFIED_WM_TICKS[i]
        local tick = unifiedAddTick(ctx, x, y, w, getText(t.label),
            getBoolOption(t.id, false), unifiedOnModTick, t)
        tick.enable = (not t.gate or sandboxGate(t.gate, true, ctx.pn) ~= false)
            and (t.id ~= "WMAnimalLivestock" or ctx.livestockMode ~= 4)
    end)
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
    unifiedAddTickCols(ctx, #UNIFIED_APPEAR_TICKS, function(i, x, y, w)
        local t = UNIFIED_APPEAR_TICKS[i]
        unifiedAddTick(ctx, x, y, w, getText(t.label), getBoolOption(t.id, t.default),
            unifiedOnModTick, t)
    end)
    unifiedAddSliderRows(ctx, UNIFIED_SLIDERS.appearance) -- 穿透模式地圖不透明度
end

-- 長提示句斷行（ISLabel 無自動換行，長句會溢出 lane——實測「無類別提示」
-- 四語皆超寬）：貪婪斷行，CJK 逐字可斷、拉丁以最後空白優先；UTF-8 逐碼點
-- 步進，絕不切壞多位元組字元。僅設定視窗重建時執行，量測成本無妨
-- indent（選配）＝整段左縮排 px（懸掛版式的描述行用）；r/g/b（選配）＝文字色
-- （預設 0.75 灰；效能區收尾建議用亮色突出）。既有呼叫端不帶新參、行為不變
local function unifiedAddWrappedNote(ctx, text, indent, r, g, b)
    indent = indent or 0
    r, g, b = r or 0.75, g or 0.75, b or 0.75
    local tm = getTextManager()
    local maxW = ctx.laneW - 10 - indent
    local s = tostring(text or "")
    local n = #s
    local lineStart = 1
    local lastSpaceEnd = nil -- 行內最後一個空白之後的 byte 位置（拉丁斷點）
    local function emit(seg)
        unifiedAdd(ctx, ISLabel:new(ctx.curX + 4 + indent, ctx.curY + 3, ctx.fontH,
            seg, r, g, b, 1, UIFont.Small, true))
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

-- 顯示距離區：說明列＋距離滑條（0＝不限；滑條上限＝伺服器允許範圍）＋效能標語。
-- 定義必須在 unifiedAddWrappedNote 之後（local 前向引用會被編譯成全域查找、
-- 執行期 nil——check_lua_bindings 守的坑）
local function unifiedBuildDistance(ctx)
    unifiedAdd(ctx, ISLabel:new(ctx.curX, ctx.curY + 3, ctx.fontH,
        getText("UI_MinidoracatMiniMap_DistNote"), 0.75, 0.75, 0.75, 1, UIFont.Small, true))
    ctx.curY = ctx.curY + ctx.rowH
    unifiedAddSliderRows(ctx, UNIFIED_SLIDERS.distance)
end

-- 效能說明分類（實測回饋 0.19.0：一行標語塞在顯示距離尾端不易發現，也放不下
-- 逐項說明）。版式＝逐項「名稱（白）＋等級（彩色右對齊）」
-- 標題列＋縮排描述行（懸掛式；取代舊「- 」前綴純文字清單——貪婪斷行會把
-- 前綴孤立成整行、續行頂格難讀，實測截圖回饋）。等級色沿家族 Okabe-Ito
-- 色盲友善向（綠／黃／橘）。等級是機制推導＋整包實測錨點（AGENTS.md
-- 2026-08-19 GameProfiler A/B：「MOD＋常駐小地圖預設設定」上界 0.56ms/幀
-- ≈ 60fps 幀預算 3.4%，文案取整約 0.6ms／約 4％）——無逐項 profiler 數據，
-- 不給逐項百分比（數字表述紀律）。
local PERF_LEVELS = {
    [0] = { key = "UI_MinidoracatMiniMap_PerfLv0", r = 0.40, g = 0.80, b = 0.40 },
    [1] = { key = "UI_MinidoracatMiniMap_PerfLv1", r = 0.90, g = 0.85, b = 0.35 },
    [2] = { key = "UI_MinidoracatMiniMap_PerfLv2", r = 0.95, g = 0.60, b = 0.25 },
}
local PERF_ITEMS = {
    { name = "UI_MinidoracatMiniMap_PerfItemMap", lvl = 0, desc = "UI_MinidoracatMiniMap_PerfDescMap" },
    { name = "UI_MinidoracatMiniMap_PerfItemPoi", lvl = 1, desc = "UI_MinidoracatMiniMap_PerfDescPoi" },
    { name = "UI_MinidoracatMiniMap_PerfItemZone", lvl = 1, desc = "UI_MinidoracatMiniMap_PerfDescZone" },
    { name = "UI_MinidoracatMiniMap_PerfItemZombie", lvl = 2, desc = "UI_MinidoracatMiniMap_PerfDescZombie" },
    { name = "UI_MinidoracatMiniMap_PerfItemAnimal", lvl = 1, desc = "UI_MinidoracatMiniMap_PerfDescAnimal" },
    { name = "UI_MinidoracatMiniMap_PerfItemMisc", lvl = 1, desc = "UI_MinidoracatMiniMap_PerfDescMisc" },
}
local function unifiedAddDivider(ctx)
    local line = ISPanel:new(ctx.curX + 4, ctx.curY + 2, ctx.laneW - 8, 1)
    line:initialise()
    line.backgroundColor = { r = 1, g = 1, b = 1, a = 0.12 }
    line.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    unifiedAdd(ctx, line)
    ctx.curY = ctx.curY + 6
end

local function unifiedBuildPerf(ctx)
    unifiedAddWrappedNote(ctx, getText("UI_MinidoracatMiniMap_PerfIntro"))
    ctx.curY = ctx.curY + 4
    unifiedAddDivider(ctx)
    local tm = getTextManager()
    for i = 1, #PERF_ITEMS do
        local item = PERF_ITEMS[i]
        local lv = PERF_LEVELS[item.lvl]
        -- 標題列：名稱白字靠左＋等級彩字右貼齊；下方描述縮排，項目間有分隔。
        unifiedAdd(ctx, ISLabel:new(ctx.curX + 4, ctx.curY + 3, ctx.fontH,
            getText(item.name), 0.92, 0.92, 0.92, 1, UIFont.Small, true))
        local lvText = getText(lv.key)
        local lvW = tm:MeasureStringX(UIFont.Small, lvText)
        unifiedAdd(ctx, ISLabel:new(ctx.curX + ctx.laneW - 6 - lvW, ctx.curY + 3, ctx.fontH,
            lvText, lv.r, lv.g, lv.b, 1, UIFont.Small, true))
        ctx.curY = ctx.curY + ctx.rowH
        unifiedAddWrappedNote(ctx, getText(item.desc), 12)
        ctx.curY = ctx.curY + 4
        if i < #PERF_ITEMS then unifiedAddDivider(ctx) end
    end
    ctx.curY = ctx.curY + 4
    unifiedAddDivider(ctx)
    unifiedAddWrappedNote(ctx, getText("UI_MinidoracatMiniMap_PerfNoteWorldmap"))
    ctx.curY = ctx.curY + 4
    -- 收尾行動建議提亮（整區唯一的「該做什麼」）
    unifiedAddWrappedNote(ctx, getText("UI_MinidoracatMiniMap_PerfAdvice"), 0, 0.88, 0.85, 0.70)
end

-- 註冊的 zone 動作列（registerZoneAction，如 Zones addon 的「生成範例檔」）：
-- [combo]+[按鈕] 一列（options 有給才有 combo）。原渲染在圖層顯示區尾端，
-- 0.14 移入「自訂區域」區塊（實測回饋：與區域設定同區才找得到）。註冊
-- action 的 addon 依家族契約必同時註冊 provider——區塊存在性由 provider 決定
local function unifiedAddZoneActions(ctx)
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

-- 自訂區域區（有外部 zone provider 才插入，見上方 OnGameBoot）：名稱遠距開關
-- ＋動態類別勾選。類別是 zones.json 選配欄位——伺服器定義什麼列什麼；MP 區域
-- 非同步到貨，重開視窗即刷新清單。已知取捨：CSV 依「當前可見類別」序列化，
-- 已停用但暫不在清單的類別（伺服器移除該類全部區域期間改勾選）會被序列化丟出
-- ——影響僅「該類別回歸時恢復顯示」，可再手動關
local function unifiedBuildZones(ctx)
    unifiedAddTick(ctx, ctx.curX + 4, ctx.curY, ctx.laneW - 6,
        getText("UI_MinidoracatMiniMap_ZoneNames"),
        getBoolOption("ZoneNames", true), unifiedOnModTick,
        { id = "ZoneNames", default = true })
    ctx.curY = ctx.curY + ctx.rowH
    unifiedAddTick(ctx, ctx.curX + 4, ctx.curY, ctx.laneW - 6,
        getTextOrNull("UI_MinidoracatMiniMap_ZoneNamesFar") or "ZoneNamesFar",
        getBoolOption("ZoneNamesFar", true), unifiedOnModTick, { id = "ZoneNamesFar" })
    ctx.curY = ctx.curY + ctx.rowH
    local cats = Core.zoneExternalCategories and Core.zoneExternalCategories() or {}
    if #cats == 0 then
        unifiedAddWrappedNote(ctx, getText("UI_MinidoracatMiniMap_ZoneNoCats"))
        unifiedAddZoneActions(ctx) -- 生成範本列不受「無類別」影響
        return
    end
    local defs = {}
    for i = 1, #cats do defs[i] = { key = cats[i] } end
    local disOpt = modOptions and modOptions:getOption("ZoneCategoryFilter")
    local dis = unifiedCsvSet(disOpt and disOpt:getValue() or "")
    unifiedAddTickCols(ctx, #cats, function(i, x, y, w)
        local key = cats[i]
        unifiedAddTick(ctx, x, y, w, key, not dis[key],
            function(target, index, selected)
                unifiedSetFilter("ZoneCategoryFilter", defs, key, selected)
            end)
    end)
    ctx.curY = ctx.curY + 2
    unifiedAddSelectAllNone(ctx, function()
        unifiedSetAllFilter("ZoneCategoryFilter", defs, true)
        unifiedRebuild(ctx.win)
    end, function()
        unifiedSetAllFilter("ZoneCategoryFilter", defs, false)
        unifiedRebuild(ctx.win)
    end)
    ctx.curY = ctx.curY + 4
    unifiedAddZoneActions(ctx)
end

-- test:addon-settings-builder:start
local function unifiedBuildAddon(ctx)
    local spec = ctx.sec and ctx.sec.addon
    if type(spec) ~= "table" then return end
    local ticks = spec.ticks
    if type(ticks) == "table" then
        for i = 1, #ticks do
            local entry = ticks[i]
            local tick = unifiedAddTick(ctx, ctx.curX + 4, ctx.curY,
                ctx.laneW - 6, getText(entry.label),
                addonRead(entry.get, entry.default == true) == true,
                unifiedOnAddonTick, entry)
            if entry.tooltip then tick.tooltip = getText(entry.tooltip) end
            ctx.curY = ctx.curY + ctx.rowH
        end
    end
    local combos = spec.combos
    if type(combos) == "table" then
        for i = 1, #combos do
            local entry = combos[i]
            unifiedAdd(ctx, ISLabel:new(ctx.curX, ctx.curY + 3, ctx.fontH,
                getText(entry.label), 1, 1, 1, 1, UIFont.Small, true))
            local combo = ISComboBox:new(ctx.curX + ctx.comboLabelW + 8, ctx.curY,
                ctx.laneW - ctx.comboLabelW - 8, ctx.fontH + 6,
                ctx.win, unifiedOnAddonCombo, entry)
            combo:initialise()
            local items = entry.items
            if type(items) == "table" then
                for j = 1, #items do combo:addOption(getText(items[j])) end
            end
            local default = entry.default or 1
            local selected = addonRead(entry.get, default)
            if type(selected) ~= "number" or selected ~= selected or selected < 1
                    or not items or selected > #items then selected = default end
            combo.selected = selected - selected % 1
            if entry.tooltip then combo.tooltip = getText(entry.tooltip) end
            unifiedAdd(ctx, combo)
            ctx.curY = ctx.curY + ctx.rowH
        end
    end
    local actions = spec.actions
    if type(actions) == "table" then
        local pn = ctx.pn or 0
        for i = 1, #actions do
            local entry = actions[i]
            local btn = unifiedAddBtn(ctx, ctx.curX + 4, ctx.curY, ctx.laneW - 6,
                getText(entry.label), unifiedOnAddonAction, getText(entry.tooltip))
            btn._addonAction = entry
            btn.enable = addonActionEnabled(entry, pn)
            ctx.curY = ctx.curY + ctx.rowH
        end
    end
end
-- test:addon-settings-builder:end

-- 管理員檢視 builder（必須定義在 unifiedAddWrappedNote 之後：local 前向引用
-- 會編成全域查找、執行期 nil）。兩個 callback 一律「setter 之後重建」——setter
-- 回的是**實際存下的值**，伺服器不允許或權限已被收回時勾選框在重建時彈回真值，
-- 而不是留下一個看起來開著、實際沒生效的假開關。
local function unifiedOnAdminTactical(target, index, selected)
    if Policy then Policy.setLocalTactical(target._playerNum or 0, selected == true) end
    unifiedRebuild(target)
end
local function unifiedOnAdminPrivacy(target, index, selected)
    if Policy then Policy.setLocalPrivacy(target._playerNum or 0, selected == true) end
    unifiedRebuild(target)
end

local function unifiedBuildAdmin(ctx)
    if not Policy then return end
    local pn = ctx.pn or 0
    unifiedAddWrappedNote(ctx, getText("UI_MinidoracatMiniMap_AdminNote"))
    ctx.curY = ctx.curY + 4
    local tacticalOn = Policy.localTactical(pn) == true
    local tick = unifiedAddTick(ctx, ctx.curX + 4, ctx.curY, ctx.laneW - 6,
        getText("UI_MinidoracatMiniMap_AdminTactical"), tacticalOn, unifiedOnAdminTactical)
    tick.tooltip = getText("UI_MinidoracatMiniMap_AdminTactical_tooltip")
    ctx.curY = ctx.curY + ctx.rowH
    -- 隱私層是戰術層的子開關：版面用縮排表達依賴，行為由 enable 釘住——伺服器
    -- 沒開第二把政策鑰匙、或戰術層還沒打開，都不可勾（勾了 setter 也會回 false）
    local privacyAllowed = Policy.readBool("AllowAdminPrivacyView", false) == true
    local sub = unifiedAddTick(ctx, ctx.curX + 20, ctx.curY, ctx.laneW - 22,
        getText("UI_MinidoracatMiniMap_AdminPrivacy"),
        Policy.localPrivacy(pn) == true, unifiedOnAdminPrivacy)
    sub.tooltip = getText("UI_MinidoracatMiniMap_AdminPrivacy_tooltip")
    sub.enable = privacyAllowed and tacticalOn
    ctx.curY = ctx.curY + ctx.rowH
    if not privacyAllowed then
        unifiedAdd(ctx, ISLabel:new(ctx.curX + 20, ctx.curY, ctx.fontH,
            getText("UI_MinidoracatMiniMap_AdminPrivacyDisabled"),
            0.95, 0.55, 0.25, 1, UIFont.Small, true))
        ctx.curY = ctx.curY + ctx.rowH
    end
end

local UNIFIED_BUILDERS = {
    layers = unifiedBuildLayers, poicat = unifiedBuildPoicat, zones = unifiedBuildZones,
    safehouse = unifiedBuildSafehouse,
    zombie = unifiedBuildZombie,
    animals = unifiedBuildAnimals, vehicles = unifiedBuildVehicles, distance = unifiedBuildDistance,
    worldmap = unifiedBuildWorldmap, appearance = unifiedBuildAppearance,
    admin = unifiedBuildAdmin,
    perf = unifiedBuildPerf,
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
    if Core.zoneExternalCategories then
        local zcats = Core.zoneExternalCategories()
        for i = 1, #zcats do max2 = math.max(max2, tw(zcats[i])) end
    end
    for i = 1, #UNIFIED_WM_TICKS do
        max2 = math.max(max2, tw(getText(UNIFIED_WM_TICKS[i].label)))
    end
    for i = 1, #SAFEHOUSE_MASTER_TICKS do
        max2 = math.max(max2, tw(getText(SAFEHOUSE_MASTER_TICKS[i].label)))
    end
    for i = 1, #UNIFIED_SECTIONS do
        local spec = UNIFIED_SECTIONS[i].addon
        local ticks = spec and spec.ticks
        if type(ticks) == "table" then
            for j = 1, #ticks do
                max2 = math.max(max2, tw(getText(ticks[j].label)))
            end
        end
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
    for i = 1, #UNIFIED_SECTIONS do
        local spec = UNIFIED_SECTIONS[i].addon
        local combos = spec and spec.combos
        if type(combos) == "table" then
            for j = 1, #combos do
                comboLabelW = math.max(comboLabelW, tw(getText(combos[j].label)))
            end
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

-- test:settings-studio-layout:start
local function studioPaneLayout(viewportW, desiredInspectorW, fontH, desiredNavW)
    local available = math.max(1, math.floor(viewportW or 0) - 8)
    local navW = math.max((fontH or 12) * 13, desiredNavW or 0)
    local inspectorW = math.max(300, desiredInspectorW or 300)
    if navW + 10 + inspectorW <= available then
        return { mode = "wide", navW = navW, inspectorW = inspectorW,
            windowW = navW + 10 + inspectorW }
    end
    return { mode = "narrow", navW = 0, inspectorW = available, windowW = available }
end
-- test:settings-studio-layout:end

-- test:settings-studio-query:start
local function studioNormalizeQuery(text)
    return (tostring(text or ""):match("^%s*(.-)%s*$") or ""):lower()
end
local function studioQuery(index, text)
    local q = studioNormalizeQuery(text)
    if q == "" then return nil end
    local out = {}
    for i = 1, #index do
        if index[i].low:find(q, 1, true) then out[#out + 1] = index[i] end
    end
    return out
end
-- test:settings-studio-query:end

local function studioIndexAdd(index, sec, labelKey, kind, mode, entry)
    local label = getTextOrNull(labelKey) or labelKey
    index[#index + 1] = { sec = sec, label = label, low = label:lower(),
        kind = kind or "navigate", mode = mode, entry = entry }
end
local function studioIndexList(index, sec, list, kind, mode)
    for i = 1, #list do studioIndexAdd(index, sec, list[i].label, kind, mode, list[i]) end
end
local function studioBuildIndex()
    local index = {}
    for i = 1, #UNIFIED_SECTIONS do
        local sec = UNIFIED_SECTIONS[i]
        studioIndexAdd(index, sec, sec.label, "category")
        if sec.addon then
            -- test:addon-settings-index:start
            studioIndexList(index, sec, sec.addon.ticks or {}, "boolean", "addon")
            studioIndexList(index, sec, sec.addon.combos or {}, "navigate")
            studioIndexList(index, sec, sec.addon.actions or {}, "navigate")
            -- test:addon-settings-index:end
        elseif sec.id == "layers" then
            for j = 1, #UNIFIED_LAYER_TICKS do
                local e = UNIFIED_LAYER_TICKS[j]
                -- ZoneLayer 的 canonical 搜尋歸「自訂區域」分類；它也存在圖層表，
                -- 若兩邊都建 hit，同一 option 會出現兩顆不同步 checkbox。
                if e.id ~= "ZoneLayer" and not (e.mpOnly and not isClient()) then
                    studioIndexAdd(index, sec, e.label, "boolean",
                        e.engine and "engine" or "mod", e)
                end
            end
        elseif sec.id == "poicat" then
            studioIndexList(index, sec, POI_MASTER_TICKS, "boolean", "mod")
            studioIndexAdd(index, sec, "UI_MinidoracatMiniMap_PoiColorIcons", "boolean", "mod",
                { id = "PoiColorIcons", default = false })
            studioIndexAdd(index, sec, "UI_MinidoracatMiniMap_PoiWholeBuilding", "boolean", "mod",
                { id = "PoiWholeBuilding", default = true })
            local order = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.ORDER
            local cats = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.CATEGORIES
            if type(order) == "table" and type(cats) == "table" then
                for j = 1, #order do
                    local def = cats[order[j]]
                    if def then studioIndexAdd(index, sec, def.nameKey, "navigate") end
                end
            end
            studioIndexList(index, sec, UNIFIED_SLIDERS.poi, "navigate")
        elseif sec.id == "safehouse" then
            studioIndexList(index, sec, SAFEHOUSE_MASTER_TICKS, "boolean", "mod")
            studioIndexList(index, sec, UNIFIED_SLIDERS.safehouse, "navigate")
        elseif sec.id == "zombie" then
            studioIndexAdd(index, sec, ZOMBIE_MASTER.label, "boolean", "mod", ZOMBIE_MASTER)
            studioIndexList(index, sec, UNIFIED_ZOMBIE_COMBOS, "navigate")
            studioIndexList(index, sec, UNIFIED_SLIDERS.zombie, "navigate")
        elseif sec.id == "animals" then
            studioIndexList(index, sec, ANIMAL_MASTER_TICKS, "boolean", "mod")
            studioIndexList(index, sec, ADOTS_SPECIES_UI, "navigate")
            studioIndexList(index, sec, UNIFIED_ANIMAL_COMBOS, "navigate")
            studioIndexList(index, sec, UNIFIED_SLIDERS.animals, "navigate")
        elseif sec.id == "vehicles" then
            studioIndexAdd(index, sec, VEHICLE_MASTER.label, "boolean", "mod", VEHICLE_MASTER)
            studioIndexList(index, sec, ADOTS_VEHCAT_UI, "navigate")
            studioIndexList(index, sec, UNIFIED_VEHICLE_COMBOS, "navigate")
            studioIndexList(index, sec, UNIFIED_SLIDERS.vehicles, "navigate")
        elseif sec.id == "worldmap" then
            studioIndexList(index, sec, UNIFIED_WM_TICKS, "boolean", "mod")
        elseif sec.id == "appearance" then
            studioIndexList(index, sec, UNIFIED_APPEAR_COMBOS, "navigate")
            studioIndexList(index, sec, UNIFIED_APPEAR_TICKS, "boolean", "mod")
            studioIndexList(index, sec, UNIFIED_SLIDERS.appearance, "navigate")
            studioIndexAdd(index, sec, "UI_MinidoracatMiniMap_ResetSize", "navigate")
        elseif sec.id == "distance" then
            studioIndexList(index, sec, UNIFIED_SLIDERS.distance, "navigate")
        elseif sec.id == "zones" then
            studioIndexAdd(index, sec, ZONE_MASTER.label, "boolean", "mod", ZONE_MASTER)
            studioIndexAdd(index, sec, "UI_MinidoracatMiniMap_ZoneNames", "boolean", "mod",
                { id = "ZoneNames", default = true })
            studioIndexAdd(index, sec, "UI_MinidoracatMiniMap_ZoneNamesFar", "boolean", "mod",
                { id = "ZoneNamesFar", default = true })
            local cats = Core.zoneExternalCategories and Core.zoneExternalCategories() or {}
            for j = 1, #cats do
                index[#index + 1] = { sec = sec, label = cats[j], low = cats[j]:lower(),
                    kind = "navigate" }
            end
            for j = 1, #registeredZoneActions do
                studioIndexAdd(index, sec, registeredZoneActions[j].labelKey, "navigate")
            end
        elseif sec.id == "admin" then
            -- 只收 kind="navigate"：搜尋結果列沒有版面承載「伺服器允許＋主開關
            -- 已開」這層閘門，直接給 checkbox 會做出點了沒反應的開關
            studioIndexAdd(index, sec, "UI_MinidoracatMiniMap_AdminTactical", "navigate")
            studioIndexAdd(index, sec, "UI_MinidoracatMiniMap_AdminPrivacy", "navigate")
        elseif sec.id == "perf" then
            for j = 1, #PERF_ITEMS do studioIndexAdd(index, sec, PERF_ITEMS[j].name, "navigate") end
        end
    end
    return index
end


local function studioBoolValue(hit, pn)
    if hit.mode == "engine" then return unifiedEngineGet(hit.entry.id, pn) end
    if hit.mode == "addon" then
        return addonRead(hit.entry.get, hit.entry.default == true) == true
    end
    return getBoolOption(hit.entry.id, hit.entry.default == true)
end
-- test:settings-studio-effective:start
local function studioSearchEnabled(hit, pn)
    local entry = hit.entry
    if hit.sec.gate and sandboxGate(hit.sec.gate, true, pn) == false then return false end
    if entry and entry.gate and sandboxGate(entry.gate, true, pn) == false then return false end
    local id = entry and entry.id
    if (id == "AnimalLivestock" or id == "WMAnimalLivestock")
            and livestockVisibilityMode(pn) == 4 then return false end
    return true
end
-- test:settings-studio-effective:end

local function studioSearchDisabledText(hit, pn)
    local id = hit.entry and hit.entry.id
    if (id == "AnimalLivestock" or id == "WMAnimalLivestock")
            and livestockVisibilityMode(pn) == 4 then
        return getText("UI_MinidoracatMiniMap_LivestockHiddenBySandbox")
    end
    return getText("UI_MinidoracatMiniMap_ServerDisabled")
end
local function studioOnSearchTick(target, index, selected, hit)
    if not studioSearchEnabled(hit, target._playerNum or 0) then return end
    if hit.mode == "engine" then
        unifiedEngineSet(hit.entry.id, selected, target._playerNum or 0)
    elseif hit.mode == "addon" then
        addonWrite(hit.entry, selected == true)
    else
        settingsApply(hit.entry, selected)
    end
    if hit.mode == "mod" and (hit.entry.id == "PlaceNames"
            or hit.entry.id == "AnimalWild" or hit.entry.id == "AnimalLivestock") then
        unifiedRebuild(target)
    end
end
local function studioSelectSection(win, sec)
    win._selectedSec = sec.id
    win._narrowPage = "inspector"
    if win._searchEntry and win._searchEntry:getInternalText() ~= "" then
        win._searchEntry:setText("")
        win._lastQuery = ""
    end
    unifiedRebuild(win)
end
local function studioOnNav(target, button)
    studioSelectSection(target, button._studioSec)
end
local function studioOnNavigateResult(target, button)
    studioSelectSection(target, button._studioHit.sec)
end
local function studioBack(target)
    if target._searchEntry then target._searchEntry:setText("") end
    target._lastQuery = ""
    target._narrowPage = "nav"
    unifiedRebuild(target)
end
local function studioSectionEnabled(sec, pn)
    return not sec.gate or sandboxGate(sec.gate, true, pn) ~= false
end
-- test:settings-studio-master:start
local function studioMasterValue(entry)
    if entry.members then
        for i = 1, #entry.members do
            local member = entry.members[i]
            if getBoolOption(member.id, member.default == true) then return true end
        end
        return false
    end
    return getBoolOption(entry.id, entry.default == true)
end

local function studioOnMaster(target, button)
    if not button.enable then return end
    local entry = button._studioMaster
    local value = not studioMasterValue(entry)
    if entry.members then
        if not modOptions then return end
        for i = 1, #entry.members do
            local option = modOptions:getOption(entry.members[i].id)
            if option then option:setValue(value) end
        end
        if modOptions.apply then modOptions:apply() end
        PZAPI.ModOptions:save()
    else
        settingsApply(entry, value)
    end
    unifiedRebuild(target)
end
-- test:settings-studio-master:end
local function studioAddMasterPill(ctx, x, y, entry, enabled)
    local button = ISButton:new(x, y, 38, 22, "", ctx.win, studioOnMaster)
    button._studioMaster = entry
    button:initialise()
    button:setEnable(enabled ~= false) -- 原版 ISButton.lua:416-426
    button.borderColor = { r = 0, g = 0, b = 0, a = 0 }
    button.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    button.backgroundColorMouseOver = { r = 0, g = 0, b = 0, a = 0 }
    unifiedAdd(ctx, button)
    ctx.win._pills[#ctx.win._pills + 1] = { panel = ctx.panel, button = button,
        x = x, y = y, w = 38, h = 22, entry = entry, enabled = enabled ~= false,
        on = studioMasterValue(entry) }
end

-- test:settings-studio-reset:start
local function studioResetId(id, value)
    if not modOptions then return false end
    local option = modOptions:getOption(id)
    if not option then return false end
    option:setValue(value)
    return true
end

local function studioResetList(list, fallback)
    local changed = false
    for i = 1, #list do
        local entry = list[i]
        if not entry.engine and entry.id then
            local value = entry.default
            if value == nil then value = fallback end
            if studioResetId(entry.id, value) then changed = true end
        end
    end
    return changed
end

local function studioSnapshotEngineStates()
    local states = {}
    for pn = 0, 3 do
        local playerObj = getSpecificPlayer(pn)
        if playerObj and getPlayerMiniMap(pn) then
            states[#states + 1] = { pn = pn,
                isometric = unifiedEngineGet("Isometric", pn),
                symbols = unifiedEngineGet("Symbols", pn),
                remoteSymbols = unifiedEngineGet("RemoteSymbols", pn) }
        end
    end
    return states
end

local function studioRestoreEngineStates(states)
    for i = 1, #states do
        local state = states[i]
        unifiedEngineSet("Isometric", state.isometric, state.pn)
        unifiedEngineSet("Symbols", state.symbols, state.pn)
        unifiedEngineSet("RemoteSymbols", state.remoteSymbols, state.pn)
    end
end

local function studioResetSection(target, button)
    local sec = button._studioSec
    if not sec or sec.id == "perf" then return end
    local changed = false
    if sec.addon then
        for i = 1, #sec.addon.ticks do
            local entry = sec.addon.ticks[i]
            addonWrite(entry, entry.default == true)
        end
        for i = 1, #sec.addon.combos do
            local entry = sec.addon.combos[i]
            addonWrite(entry, entry.default or 1)
        end
    elseif sec.id == "layers" then
        changed = studioResetList(UNIFIED_LAYER_TICKS, false)
    elseif sec.id == "poicat" then
        changed = studioResetList(POI_MASTER_TICKS, false)
        if studioResetId("PoiColorIcons", false) then changed = true end
        if studioResetId("PoiWholeBuilding", true) then changed = true end
        local order = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.ORDER
        if type(order) == "table" then
            for i = 1, #order do
                if studioResetId("Cat_" .. order[i], true) then changed = true end
            end
        end
        if studioResetList(UNIFIED_SLIDERS.poi, 0) then changed = true end
    elseif sec.id == "safehouse" then
        changed = studioResetList(SAFEHOUSE_MASTER_TICKS, false)
        if studioResetList(UNIFIED_SLIDERS.safehouse, 0) then changed = true end
    elseif sec.id == "zombie" then
        changed = studioResetId(ZOMBIE_MASTER.id, ZOMBIE_MASTER.default)
        if studioResetList(UNIFIED_ZOMBIE_COMBOS, 1) then changed = true end
        if studioResetList(UNIFIED_SLIDERS.zombie, 0) then changed = true end
    elseif sec.id == "animals" then
        changed = studioResetList(ANIMAL_MASTER_TICKS, false)
        if studioResetId("AnimalSpeciesFilter", "-") then changed = true end
        if studioResetList(UNIFIED_ANIMAL_COMBOS, 1) then changed = true end
        if studioResetList(UNIFIED_SLIDERS.animals, 0) then changed = true end
    elseif sec.id == "vehicles" then
        changed = studioResetId(VEHICLE_MASTER.id, VEHICLE_MASTER.default)
        if studioResetId("VehicleCategoryFilter", "-") then changed = true end
        if studioResetList(UNIFIED_VEHICLE_COMBOS, 1) then changed = true end
        if studioResetList(UNIFIED_SLIDERS.vehicles, 0) then changed = true end
    elseif sec.id == "worldmap" then
        changed = studioResetList(UNIFIED_WM_TICKS, false)
    elseif sec.id == "appearance" then
        changed = studioResetList(UNIFIED_APPEAR_COMBOS, 1)
        if studioResetList(UNIFIED_APPEAR_TICKS, false) then changed = true end
        if studioResetList(UNIFIED_SLIDERS.appearance, 0) then changed = true end
        if studioResetId("CustomSize", "") then changed = true end
    elseif sec.id == "distance" then
        changed = studioResetList(UNIFIED_SLIDERS.distance, 0)
    elseif sec.id == "zones" then
        changed = studioResetId(ZONE_MASTER.id, ZONE_MASTER.default)
        if studioResetId("ZoneNames", true) then changed = true end
        if studioResetId("ZoneNamesFar", true) then changed = true end
        if studioResetId("ZoneCategoryFilter", "-") then changed = true end
    elseif sec.id == "admin" then
        -- 只清本機旗標（依 facade 契約連帶清隱私）。刻意不碰沙盒、也不進
        -- changed／modOptions:apply 路徑：這兩個值不在 ModOptions，
        -- 「重設此分類」更不該把全服政策一起改掉
        if Policy then Policy.setLocalTactical(target._playerNum or 0, false) end
    end
    if changed then
        -- apply() 目前只重建／套用 P0，但 reset 可由任一 split-screen 玩家觸發。
        -- 快照所有現存 local mini-map，避免 P2 操作後 P0 的原生 flags 被連帶改寫。
        local engineStates = studioSnapshotEngineStates()
        if modOptions.apply then modOptions:apply() end
        studioRestoreEngineStates(engineStates)
        PZAPI.ModOptions:save()
    end
    unifiedRebuild(target)
end
-- test:settings-studio-reset:end

local function studioClearRows(win)
    if win._nav then win._navScroll = win._nav:getYScroll() end
    if win._renderedScrollKey and win._content then
        win._scrollBySection[win._renderedScrollKey] = win._content:getYScroll()
    end
    for i = 1, #win._rows do
        local row = win._rows[i]
        if row.parent then row.parent:removeChild(row) end
    end
    win._rows, win._navRows, win._pills, win._icons, win._cards = {}, {}, {}, {}, {}
end

local function studioSetupPanel(win)
    local panel = ISPanel:new(0, win:titleBarHeight(), win.width, 100)
    panel:initialise()
    panel.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
    panel.borderColor = { r = 0, g = 0, b = 0, a = 0 }
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
        local w, Skin = self.parent, Core.Skin
        if Skin then
            for i = 1, #w._cards do
                local card = w._cards[i]
                if card.panel == self then
                    Skin.fill(self, card.x, card.y, card.w, card.h, Skin.COLORS.ROW_HOVER)
                    Skin.border(self, card.x, card.y, card.w, card.h,
                        Skin.COLORS.BORDER, false, 0.35)
                end
            end
        end
    end
    function panel:render()
        ISPanel.render(self)
        local w = self.parent
        local Skin = Core.Skin
        for i = 1, #w._navRows do
            local row = w._navRows[i]
            if row.button.parent == self then
                local selected = w._selectedSec == row.sec.id
                local hover = row.button.mouseOver
                if Skin then
                    Skin.fill(self, row.x, row.y, row.w, row.h,
                        selected and Skin.COLORS.ROW_SELECTED or Skin.COLORS.ROW_HOVER,
                        false, hover and 1.5 or 1)
                elseif selected or hover then
                    self:drawRect(row.x, row.y, row.w, row.h,
                        selected and 0.12 or 0.06, 1, 1, 1)
                end
                local color = selected and Skin and Skin.COLORS.ACCENT_AMBER or nil
                local textX = row.x + 10
                if row.sec.icon and Skin and Skin.icon
                        and Skin.icon(self, row.sec.icon, row.x + 8, row.y + 5, 16,
                            color or Skin.COLORS.TEXT_MUTED) then
                    textX = row.x + 30
                end
                self:drawText(getText(row.sec.label), textX, row.y + 7,
                    color and color.r or 0.9, color and color.g or 0.9,
                    color and color.b or 0.9, 1, UIFont.Small)
            end
        end
        for i = 1, #w._pills do
            local p = w._pills[i]
            if p.panel == self then
                local painted = Skin and Skin.toggle
                    and Skin.toggle(self, p.x, p.y, p.w, p.h, p.on, nil,
                        p.enabled and 1 or 0.4)
                if not painted then
                    local scale = p.enabled and 1 or 0.4
                    self:drawRect(p.x, p.y, p.w, p.h, (p.on and 0.35 or 0.12) * scale,
                        p.on and 1 or 0.5, p.on and 0.85 or 0.5, p.on and 0.4 or 0.5)
                    local knobX = p.on and (p.x + p.w - 18) or (p.x + 4)
                    self:drawRect(knobX, p.y + 4, 14, 14, scale, 0.9, 0.9, 0.9)
                end
            end
        end
        for i = 1, #w._icons do
            local ic = w._icons[i]
            if ic.panel == self then
                local tex = ic.tex or (ic.name and adotsTexture and adotsTexture(ic.name))
                if tex then
                    self:drawTextureScaled(tex, ic.x, ic.y + 1, ic.size, ic.size, 1,
                        ic.r or 0.92, ic.g or 0.92, ic.b or 0.92)
                end
            end
        end
        self:clearStencilRect()
    end
    win:addChild(panel)
    return panel
end
local function studioSetScroll(panel, contentH, panelH, wanted)
    panel:setHeight(panelH)
    panel:setScrollHeight(math.max(contentH, panelH))
    local maxScroll = math.max(0, contentH - panelH)
    local ys = wanted or 0
    if ys < -maxScroll then ys = -maxScroll end
    if ys > 0 then ys = 0 end
    panel:setYScroll(ys)
    if panel.vscroll then
        panel.vscroll:setHeight(panelH)
        panel.vscroll:setX(panel.width - 12)
    end
end
local function studioBuildNav(ctx)
    ctx.curX, ctx.curY = 8, 4
    for i = 1, #UNIFIED_SECTIONS do
        local sec = UNIFIED_SECTIONS[i]
        local pillW = sec.master and 48 or 0
        local button = ISButton:new(ctx.curX, ctx.curY, ctx.laneW - pillW,
            ctx.rowH + 8, "", ctx.win, studioOnNav)
        button._studioSec = sec
        button:initialise()
        button.borderColor = { r = 0, g = 0, b = 0, a = 0 }
        button.backgroundColor = { r = 0, g = 0, b = 0, a = 0 }
        button.backgroundColorMouseOver = { r = 0, g = 0, b = 0, a = 0 }
        unifiedAdd(ctx, button)
        ctx.win._navRows[#ctx.win._navRows + 1] = { button = button, sec = sec,
            x = ctx.curX, y = ctx.curY, w = ctx.laneW - 4, h = ctx.rowH + 8 }
        if sec.master then
            studioAddMasterPill(ctx, ctx.curX + ctx.laneW - 46,
                ctx.curY + math.floor((ctx.rowH - 14) / 2), sec.master,
                studioSectionEnabled(sec, ctx.pn))
        end
        ctx.curY = ctx.curY + ctx.rowH + 10
    end
    return ctx.curY + 4
end
local function studioBuildSearchResults(ctx, hits)
    ctx.curX, ctx.curY = 10, 8
    if ctx.showBack then
        unifiedAddBtn(ctx, ctx.curX, ctx.curY, math.min(100, ctx.laneW),
            getText("UI_MinidoracatMiniMap_StudioBack"), studioBack)
        ctx.curY = ctx.curY + ctx.rowH + 8
    end
    if #hits == 0 then
        unifiedAddWrappedNote(ctx, getText("UI_MinidoracatMiniMap_StudioNoResults"))
        return ctx.curY + 8
    end
    local cardY = ctx.curY - 4
    for i = 1, #hits do
        local hit = hits[i]
        local text = getText(hit.sec.label) .. " / " .. hit.label
        if hit.kind == "boolean" then
            local enabled = studioSearchEnabled(hit, ctx.pn)
            if not enabled then text = text .. " - " .. studioSearchDisabledText(hit, ctx.pn) end
            local tick = unifiedAddTick(ctx, ctx.curX + 4, ctx.curY, ctx.laneW - 8, text,
                studioBoolValue(hit, ctx.pn), studioOnSearchTick, hit)
            tick.enable = enabled -- ISTickBox.lua:72-76/142-164
        else
            local button = unifiedAddBtn(ctx, ctx.curX + 4, ctx.curY,
                ctx.laneW - 8, text, studioOnNavigateResult)
            button._studioHit = hit
        end
        ctx.curY = ctx.curY + ctx.rowH + 2
    end
    ctx.win._cards[#ctx.win._cards + 1] = { panel = ctx.panel, x = 6, y = cardY,
        w = ctx.laneW + 8, h = math.max(ctx.rowH, ctx.curY - cardY + 2) }
    return ctx.curY + 8
end

local function studioFindSection(id)
    for i = 1, #UNIFIED_SECTIONS do
        if UNIFIED_SECTIONS[i].id == id then return UNIFIED_SECTIONS[i] end
    end
    return UNIFIED_SECTIONS[1]
end

local function studioBuildInspector(ctx, sec)
    ctx.curX, ctx.curY = 10, 6
    if ctx.showBack then
        unifiedAddBtn(ctx, ctx.curX, ctx.curY, math.min(100, ctx.laneW),
            getText("UI_MinidoracatMiniMap_StudioBack"), studioBack)
        ctx.curY = ctx.curY + ctx.rowH + 8
    end
    unifiedAdd(ctx, ISLabel:new(ctx.curX + 2, ctx.curY + 2, ctx.fontH,
        getText(sec.label), 1, 0.85, 0.4, 1, UIFont.Medium, true))
    if sec.master then
        studioAddMasterPill(ctx, ctx.curX + ctx.laneW - 44, ctx.curY, sec.master,
            studioSectionEnabled(sec, ctx.pn))
    end
    ctx.curY = ctx.curY + getTextManager():getFontHeight(UIFont.Medium) + 10
    local cardY = ctx.curY - 4
    if sec.gate and sandboxGate(sec.gate, true, ctx.pn) == false then
        unifiedAdd(ctx, ISLabel:new(ctx.curX + 4, ctx.curY, ctx.fontH,
            getText("UI_MinidoracatMiniMap_ServerDisabled"),
            0.95, 0.55, 0.25, 1, UIFont.Small, true))
        ctx.curY = ctx.curY + ctx.rowH
    end
    local builder = sec.addon and unifiedBuildAddon or UNIFIED_BUILDERS[sec.id]
    if builder then ctx.sec = sec; builder(ctx); ctx.sec = nil end
    if sec.id ~= "perf" then
        ctx.curY = ctx.curY + 8
        local resetText = getText("UI_MinidoracatMiniMap_StudioResetCategory")
        local resetW = math.min(ctx.laneW, math.max(120, utw(resetText) + 20))
        local reset = unifiedAddBtn(ctx, ctx.curX + ctx.laneW - resetW,
            ctx.curY, resetW, resetText, studioResetSection,
            getText("UI_MinidoracatMiniMap_StudioResetCategory_tooltip"))
        reset._studioSec = sec
        ctx.curY = ctx.curY + ctx.rowH + 4
    end
    ctx.win._cards[#ctx.win._cards + 1] = { panel = ctx.panel, x = 6, y = cardY,
        w = ctx.laneW + 8, h = math.max(ctx.rowH, ctx.curY - cardY + 2) }
    return ctx.curY + 8
end

-- 全清重建仍是唯一同步模型；只保存選取分類與各分類/搜尋的 yScroll。
unifiedRebuild = function(win)
    local pn = win._playerNum or 0
    -- 分類成員是 live 值（政策、引擎權限、本機旗標都可能在視窗開著時變）：
    -- 先同步成員再清列，成員有變時搜尋索引必須一併重建
    if adminSectionSync(pn) and win._searchIndex then
        win._searchIndex = studioBuildIndex()
    end
    studioClearRows(win)
    local viewportW = getPlayerScreenWidth(pn)
    local viewportH = getPlayerScreenHeight(pn)
    local measure = unifiedMeasureLayout()
    local tm = getTextManager()
    local navNeed = measure.fontH * 13
    for i = 1, #UNIFIED_SECTIONS do
        local sec = UNIFIED_SECTIONS[i]
        local labelW = tm:MeasureStringX(UIFont.Small, getText(sec.label))
        local chromeW = (sec.master and 52 or 8) + (sec.icon and 24 or 0)
        navNeed = math.max(navNeed, labelW + chromeW + 20)
    end
    local desiredInspectorW = math.max(measure.laneW + 34, measure.fontH * 34)
    local pane = studioPaneLayout(viewportW, desiredInspectorW, measure.fontH, navNeed)
    local titleH = win:titleBarHeight()
    local searchH = measure.fontH + 10
    local toolbarH = searchH + 16
    local preferredBodyH = math.max(540, measure.rowH * 24)
    local bodyH = math.min(preferredBodyH,
        math.max(1, viewportH - titleH - toolbarH - 8))
    local W = pane.windowW
    win._minidoracatLivestockMode = livestockVisibilityMode(pn)
    win:setWidth(W)
    win:setHeight(titleH + toolbarH + bodyH)
    local tbBtn = win.pinButton or win.collapseButton
    local tbH = tbBtn and tbBtn.height or 16
    if win.pinButton then win.pinButton:setX(W - 1 - tbH) end
    if win.collapseButton then win.collapseButton:setX(W - 1 - tbH) end
    win._searchEntry:setX(10)
    win._searchEntry:setY(titleH + 8)
    win._searchEntry:setHeight(searchH)
    win._searchEntry:setWidth(math.max(1, W - 20))
    local bodyY = titleH + toolbarH
    local query = studioNormalizeQuery(win._searchEntry:getInternalText())
    local hits = studioQuery(win._searchIndex, query)
    local selected = studioFindSection(win._selectedSec)
    win._selectedSec = selected.id

    local nav, content = win._nav, win._content
    nav:setVisible(false)
    content:setVisible(false)
    -- 導覽欄只排分類列與母開關 pill，量測欄寬/欄數一概用不到
    local navCtx = { win = win, panel = nav, pn = pn, rowH = measure.rowH }
    local inspectorW = pane.inspectorW
    local contentCtx = { win = win, panel = content, pn = pn, livestockMode = win._minidoracatLivestockMode,
        fontH = measure.fontH, rowH = measure.rowH, laneW = math.max(1, inspectorW - 34),
        comboLabelW = math.min(measure.comboLabelW, math.max(0, inspectorW - 150)),
        cols2 = measure.cols2, cols3 = measure.cols3, poiCols = measure.poiCols,
        showBack = pane.mode == "narrow" }
    contentCtx.colW2 = math.floor((contentCtx.laneW - 6) / contentCtx.cols2)
    contentCtx.colW3 = math.floor((contentCtx.laneW - 6) / contentCtx.cols3)
    contentCtx.colWpoi = math.floor((contentCtx.laneW - 6) / contentCtx.poiCols)

    -- wide＝導覽與 inspector 併排；narrow＝單頁，搜尋結果或選定分類優先於導覽
    local showInspector = pane.mode == "wide" or hits ~= nil or win._narrowPage == "inspector"
    local showNav = pane.mode == "wide" or not showInspector
    if showNav then
        local navW = pane.mode == "wide" and pane.navW or W
        navCtx.laneW = navW - 16
        nav:setX(0); nav:setY(bodyY); nav:setWidth(navW); nav:setVisible(true)
        studioSetScroll(nav, studioBuildNav(navCtx), bodyH, win._navScroll or 0)
    end
    win._renderedScrollKey = nil
    if showInspector then
        content:setX(showNav and pane.navW + 10 or 0)
        content:setY(bodyY); content:setWidth(inspectorW); content:setVisible(true)
        local contentH = hits and studioBuildSearchResults(contentCtx, hits)
            or studioBuildInspector(contentCtx, selected)
        local scrollKey = hits and "__search" or selected.id
        studioSetScroll(content, contentH, bodyH, win._scrollBySection[scrollKey] or 0)
        win._renderedScrollKey = scrollKey
    end
    if win:isVisible() then
        local sx, sy = getPlayerScreenLeft(pn), getPlayerScreenTop(pn)
        local sw, sh = viewportW, viewportH
        local x, y = win:getX(), win:getY()
        if x + win.width > sx + sw then x = sx + sw - win.width end
        if x < sx then x = sx end
        if y + win.height > sy + sh then y = sy + sh - win.height end
        if y < sy then y = sy end
        win:setX(x); win:setY(y)
    end
end

-- 自訂區域資料到貨時的視窗自動刷新（實測回饋：視窗開著按「生成範例檔」，
-- 類別勾選不會自己長出來——重建僅在開窗/操作時觸發）。zone 快取是原子替換
-- （C2 契約：provider 恆回快取參照、更新即換新表），參照變＝資料變：逐外部
-- provider 比參照，變了才重建。每幀成本＝外部 provider 數次 pcall（fn 只回
-- 參照，純 Lua）＋等值比較；provider 拋錯記為 false、恢復時同樣觸發重建
local function unifiedZoneRefsDirty(win)
    local refs = win._minidoracatZoneRefs
    if not refs then
        refs = {}
        win._minidoracatZoneRefs = refs
    end
    local dirty = false
    for i = 1, #registeredZoneProviders do
        local p = registeredZoneProviders[i]
        if not p.internal then
            local ok, zones = pcall(p.fn)
            local ref = (ok and zones) or false
            local key = p.owner or ("#" .. i)
            if refs[key] ~= ref then
                refs[key] = ref
                dirty = true
            end
        end
    end
    return dirty
end

-- test:settings-studio-live:start
local function studioLiveSettingsDirty(win)
    local pn = win._playerNum or 0
    local zombie = sandboxGate("AllowZombieDots", true, pn) ~= false
    local animals = sandboxGate("AllowAnimalDots", true, pn) ~= false
    local vehicles = sandboxGate("AllowVehicleDots", true, pn) ~= false
    local livestock = livestockVisibilityMode(pn)
    local dirty = win._liveZombie ~= zombie or win._liveAnimals ~= animals
        or win._liveVehicles ~= vehicles or win._liveLivestock ~= livestock
    win._liveZombie, win._liveAnimals = zombie, animals
    win._liveVehicles, win._liveLivestock = vehicles, livestock
    local caps = win._liveDistanceCaps
    if not caps then caps = {}; win._liveDistanceCaps = caps; dirty = true end
    -- 距離 cap 追蹤涵蓋「顯示距離」區與「安全屋」區兩組滑條（後者以 100+ 偏移鍵存）
    for i = 1, #UNIFIED_SLIDERS.distance do
        local capBy = UNIFIED_SLIDERS.distance[i].capBy
        if capBy then
            local cap = sandboxDist and sandboxDist(capBy, pn) or nil
            if caps[i] ~= cap then caps[i] = cap; dirty = true end
        end
    end
    for i = 1, #UNIFIED_SLIDERS.safehouse do
        local cap = sandboxDist and sandboxDist(UNIFIED_SLIDERS.safehouse[i].capBy, pn) or nil
        if caps[100 + i] ~= cap then caps[100 + i] = cap; dirty = true end
    end
    -- policy revision＝沙盒值或本機旗標的變動計數；role eligibility 另需逐幀
    -- 輪詢——管理員被升／降權不經任何寫入路徑，revision 不會動，只能直接比資格
    local rev = Policy and Policy.getRevision() or 0
    local admin = adminSectionEligible(pn)
    if win._liveRev ~= rev or win._liveAdmin ~= admin then dirty = true end
    win._liveRev, win._liveAdmin = rev, admin
    return dirty
end
-- test:settings-studio-live:end

local function studioRebuildDirty(win, structuralDirty)
    if structuralDirty then win._searchIndex = studioBuildIndex() end
    unifiedRebuild(win)
end

-- test:settings-studio-titlebar:start
-- 標題列 chrome 共用繪製：原生按鈕底框 ＋ 20px 上限的 UI framework 圖示，缺資產退回單字母。
-- 上限與置中算式只留這一份，兩顆按鈕才不會日後各長各的。
local function studioTitleBarIcon(self, key, fallback, color)
    ISButton.render(self)
    local size = math.max(10, math.min(20, self.width - 4, self.height - 4))
    local x, y = math.floor((self.width - size) / 2), math.floor((self.height - size) / 2)
    local Skin = Core.Skin
    if Skin and Skin.icon and Skin.icon(self, key, x, y, size, color) then return end
    self:drawTextCentre(fallback, self.width / 2,
        math.floor((self.height - getTextManager():getFontHeight(UIFont.Medium)) / 2),
        color and color.r or 0.8, color and color.g or 0.8,
        color and color.b or 0.8, 1, UIFont.Medium)
end

-- 鎖定＝lock 圖示＋琥珀，解鎖＝unlock 圖示＋灰；hover 一律 primary。
local function studioLockButtonRender(self)
    local Skin = Core.Skin
    local color = Skin and (self._studioLocked
        and Skin.COLORS.ACCENT_AMBER or Skin.COLORS.TEXT_MUTED)
    if self.mouseOver and Skin then color = Skin.COLORS.TEXT_PRIMARY end
    studioTitleBarIcon(self, self._studioLocked and "lock" or "unlock",
        self._studioLocked and "L" or "U", color)
end

local function studioStyleLockButton(button, locked)
    if not button then return end
    button:setImage(nil) -- 原版 ISButton.lua:179-180
    button._studioLocked = locked
    button.render = studioLockButtonRender
    button.tooltip = getText(locked and "UI_MinidoracatMiniMap_StudioUnlock"
        or "UI_MinidoracatMiniMap_StudioLock")
end

local function studioCloseButtonRender(self)
    local Skin = Core.Skin
    local color = Skin and (self.mouseOver
        and Skin.COLORS.ACCENT_AMBER or Skin.COLORS.TEXT_MUTED)
    studioTitleBarIcon(self, "close", "X", color)
end

local function studioStyleCloseButton(button)
    if not button then return end
    button:setImage(nil)
    button.render = studioCloseButtonRender
    button.tooltip = getText("UI_MinidoracatMiniMap_StudioClose")
end
-- test:settings-studio-titlebar:end


local function buildSettingsWindow()
    local win = ISCollapsableWindow:new(0, 0, 700, 200) -- 寬高由 unifiedRebuild 重算
    -- Medium font 同時提高 titleBarHeight；原生 createChildren 會據此放大三顆標題列按鈕。
    win.titleFont = UIFont.Medium
    win.titleBarFont = UIFont.Medium
    win.titleFontHgt = getTextManager():getFontHeight(UIFont.Medium)
    win.resizable = false -- 同圖層面板做法（ISMiniMap.lua:187）
    win:setTitle(getText("UI_MinidoracatMiniMap_StudioTitle"))
    win:initialise()
    -- titlebar children 由 addToUIManager/instantiate 建立，換 chrome 必須在其後執行。
    -- 家族圓角皮膚（Core.Skin，同搜尋視窗；移植自 NoticeBoard NBSkin）：
    -- 關掉原生框改自畫。drawFrame 用欄位賦值、不走 setDrawFrame——那個 setter
    -- 會連 closeButton 一起藏（ISCollapsableWindow.lua:356-360）。原生 prerender
    -- 在兩旗標 false 時只剩 stencil 段（:152-176），照常回呼保留裁切
    win.drawFrame = false
    win.background = false
    local origWinPrerender = win.prerender
    win.prerender = function(self)
        local Skin = Core.Skin
        local th = self:titleBarHeight()
        local h = self.isCollapsed and th or self.height -- 收合＝只剩標題列（原生 :153-157 同判）
        if Skin then
            Skin.fill(self, 0, 0, self.width, h, Skin.COLORS.BG_PANEL)
            -- 收合時標題列＝整窗，四角全圓（topOnly=false）；展開時只圓上兩角
            Skin.fill(self, 0, 0, self.width, th, Skin.COLORS.TITLEBAR_FILL, not self.isCollapsed)
            Skin.border(self, 0, 0, self.width, h, Skin.COLORS.BORDER)
        else -- 皮膚缺席（貼圖壞）退回原生同款直角
            self:drawRect(0, 0, self.width, h, 0.8, 0, 0, 0)
            self:drawRectBorder(0, 0, self.width, h, 1, 0.4, 0.4, 0.4)
        end
        if self.title then
            local titleY = math.floor((th - self.titleFontHgt) / 2)
            self:drawTextCentre(self.title, self.width / 2, titleY,
                1, 1, 1, 1, self.titleBarFont)
        end
        origWinPrerender(self)
    end
    win:addToUIManager()
    -- 保留 ISCollapsableWindow 原生 close／pin／collapse 狀態機，只換 UI framework
    -- 的 modern chrome（ISCollapsableWindow.lua:55-91/138-149）。
    studioStyleCloseButton(win.closeButton)
    studioStyleLockButton(win.collapseButton, true)
    studioStyleLockButton(win.pinButton, false)
    win:setVisible(false)
    win._rows, win._navRows, win._pills, win._icons, win._cards = {}, {}, {}, {}, {}
    win._scrollBySection = {}
    win._selectedSec = UNIFIED_SECTIONS[1].id
    win._narrowPage = "nav"
    win._lastQuery = ""
    win._playerNum = 0
    win._lastRawQuery = ""
    win._searchEntry = ISTextEntryBox:new("", 10, win:titleBarHeight() + 8, 300, 24)
    win._searchEntry:initialise()
    win._searchEntry:instantiate()
    if win._searchEntry.setClearButton then win._searchEntry:setClearButton(true) end
    if win._searchEntry.setPlaceholderText then
        win._searchEntry:setPlaceholderText(getText("UI_MinidoracatMiniMap_StudioSearchHint"))
    end
    win:addChild(win._searchEntry)
    win._nav = studioSetupPanel(win)
    win._content = studioSetupPanel(win)
    win._searchIndex = studioBuildIndex()
    unifiedRebuild(win)
    unifiedZoneRefsDirty(win) -- 播種參照快照（避免首幀誤判 dirty 多重建一次）
    studioLiveSettingsDirty(win) -- 播種 sandbox/effective-distance signature
    -- 視窗開啟期間只在 query、結構或 live sandbox signature 改變時重建；
    -- raw query 未變時不重做 match/lower，signature table 只在首輪配置。
    local originalSettingsPrerender = win.prerender
    function win:prerender()
        local rawQuery = self._searchEntry:getInternalText()
        local query = self._lastQuery
        if rawQuery ~= self._lastRawQuery then
            self._lastRawQuery = rawQuery
            query = studioNormalizeQuery(rawQuery)
        end
        local structuralDirty = unifiedZoneRefsDirty(self)
        local liveDirty = studioLiveSettingsDirty(self)
        if query ~= self._lastQuery or structuralDirty or liveDirty
                or self._studioRebuildRetry then
            self._lastQuery = query
            local ok, err = pcall(studioRebuildDirty, self, structuralDirty)
            if ok then
                self._studioRebuildRetry = nil
                self._studioRebuildErrLogged = nil
            else
                self._studioRebuildRetry = true
                if not self._studioRebuildErrLogged then
                    self._studioRebuildErrLogged = true
                    print("[MinidoracatMiniMap] settings rebuild failed, retrying: "
                        .. tostring(err))
                end
            end
        end
        originalSettingsPrerender(self)
    end
    local originalClose = win.close
    function win:close()
        if self._searchEntry and self._searchEntry.unfocus then self._searchEntry:unfocus() end
        originalClose(self)
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
            settingsUI:close()
            return
        end
        if settingsUI._searchEntry and settingsUI._searchEntry.unfocus then
            settingsUI._searchEntry:unfocus()
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
-- 外部改動引擎選項後的視窗刷新（小地圖視角鈕等）：視窗開著且屬同玩家才重建——
-- 重建＝勾選框重讀現值（同 unifiedOnModTick 的 PlaceNames 分支「重建即同步」先例）；
-- 關著/他人視窗不動（開窗本就重建、他人視窗讀的是他自己的小地圖）
Core.refreshSettingsWindow = function(pn)
    if settingsUI and settingsUI:isVisible() and settingsUI._playerNum == (pn or 0) then
        unifiedRebuild(settingsUI)
    end
end

-- 公開 addon client-settings API v2。ownerModId 是唯一身分：同 owner 重註冊
-- 視為熱重載更新，不同 addon 即使自選同名 label 也不互相覆蓋。外部 spec
-- 在註冊期完整驗證並複製；壞值 fail closed，不得把整個 MiniMap 設定窗炸掉。
-- 導覽列只顯示分類名稱與主開關，不讀取、保存或計算摘要／數量 callback。
-- test:addon-settings-registry:start
local function normalizeAddonSettings(ownerModId, spec)
    if type(ownerModId) ~= "string" or ownerModId == ""
            or type(spec) ~= "table" or type(spec.label) ~= "string"
            or spec.label == "" then return nil end
    -- API v1 相容：舊呼叫端可繼續傳 spec.lane，但地圖顯示設定不讀、不正規化、
    -- 不複製也不保存它；分類順序只由註冊順序決定。v2 另複製 actions（最多 16）。
    local out = { label = spec.label, ticks = {}, combos = {}, actions = {} }
    local ticks = spec.ticks
    if ticks ~= nil and type(ticks) ~= "table" then return nil end
    local tickN = ticks and #ticks or 0
    if tickN > 32 then return nil end
    for i = 1, tickN do
        local e = ticks[i]
        if type(e) ~= "table" or type(e.label) ~= "string" or e.label == ""
                or type(e.get) ~= "function" or type(e.set) ~= "function"
                or (e.tooltip ~= nil and type(e.tooltip) ~= "string")
                or (e.default ~= nil and type(e.default) ~= "boolean") then return nil end
        out.ticks[i] = { label = e.label, tooltip = e.tooltip,
            default = e.default == true, get = e.get, set = e.set }
    end
    local combos = spec.combos
    if combos ~= nil and type(combos) ~= "table" then return nil end
    local comboN = combos and #combos or 0
    if comboN > 32 then return nil end
    for i = 1, comboN do
        local e = combos[i]
        if type(e) ~= "table" then return nil end
        local items = e.items
        local itemN = type(items) == "table" and #items or 0
        if type(e.label) ~= "string" or e.label == ""
                or type(e.get) ~= "function" or type(e.set) ~= "function"
                or (e.tooltip ~= nil and type(e.tooltip) ~= "string")
                or (e.default ~= nil and type(e.default) ~= "number")
                or itemN < 1 or itemN > 20 then return nil end
        for j = 1, itemN do
            if type(items[j]) ~= "string" or items[j] == "" then return nil end
        end
        local default = e.default or 1
        if default % 1 ~= 0 or default < 1 or default > itemN then return nil end
        local copyItems = {}
        for j = 1, itemN do copyItems[j] = items[j] end
        out.combos[i] = { label = e.label, tooltip = e.tooltip,
            default = default, get = e.get, set = e.set, items = copyItems }
    end
    local actions = spec.actions
    if actions ~= nil and type(actions) ~= "table" then return nil end
    local actionN = actions and #actions or 0
    if actionN > 16 then return nil end
    for i = 1, actionN do
        local e = actions[i]
        if type(e) ~= "table" or type(e.label) ~= "string" or e.label == ""
                or type(e.tooltip) ~= "string" or e.tooltip == ""
                or type(e.run) ~= "function"
                or (e.enabled ~= nil and type(e.enabled) ~= "function") then return nil end
        out.actions[i] = { label = e.label, tooltip = e.tooltip,
            run = e.run, enabled = e.enabled }
    end
    return out
end

MinidoracatMiniMapAPI.settingsApiVersion = 2
function MinidoracatMiniMapAPI.registerSettingsSection(ownerModId, spec)
    local normalized = normalizeAddonSettings(ownerModId, spec)
    if not normalized then
        print("[MinidoracatMiniMap] registerSettingsSection bad arguments: "
            .. tostring(ownerModId))
        return false
    end
    local sec = addonSettingsById[ownerModId]
    local sectionId = "addon_" .. ownerModId
    if sec then
        sec.label = normalized.label
        sec.addon = normalized
    else
        sec = { id = sectionId, label = normalized.label, addon = normalized, icon = "layers" }
        addonSettingsById[ownerModId] = sec
        local insertAt = #UNIFIED_SECTIONS + 1
        for i = 1, #UNIFIED_SECTIONS do
            if UNIFIED_SECTIONS[i].id == "perf" then insertAt = i; break end
        end
        table.insert(UNIFIED_SECTIONS, insertAt, sec)
    end
    if settingsUI then settingsUI._searchIndex = studioBuildIndex() end
    if settingsUI and settingsUI:isVisible() then unifiedRebuild(settingsUI) end
    return true
end
-- test:addon-settings-registry:end

Events.OnGameStart.Add(function()
    if settingsUI then
        if settingsUI._searchEntry and settingsUI._searchEntry.unfocus then
            pcall(function() settingsUI._searchEntry:unfocus() end)
        end
        settingsUI:setVisible(false)
        settingsUI:removeFromUIManager()
        settingsUI = nil
    end
end)
