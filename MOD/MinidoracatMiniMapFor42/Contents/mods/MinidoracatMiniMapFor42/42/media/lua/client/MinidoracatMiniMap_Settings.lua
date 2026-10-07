-- MinidoracatMiniMap_Settings.lua
-- 本檔範圍：地圖顯示設定視窗——分類資料表、addon-conditional 選項、settingsApply 管線、
-- 篩選寫入、搜尋索引、重設、效果預覽、視窗（UI 框架 rev 17 元件）與生命週期，以及公開 API
-- registerSettingsSection（settingsApiVersion 5）。
-- 載入順序假設：PZ 依字母序載入同目錄 lua，'.'(0x2E) < '_'(0x5F) → 主檔必先載入並
-- 建好 MinidoracatMiniMapCore 命名空間；本檔載入期只讀取其「一次性賦值」的穩定引用
-- 並定義函式/掛事件，跨檔「函式呼叫」一律發生在事件/呼叫時。
-- 拆檔緣由：Kahlua 編譯器每個函式原型（含每檔主 chunk）locvar 上限 200
-- （LexState.new_localvar 固定陣列，超過＝整檔拒載）——新 helper 優先掛表，不再開頂層 local。
local Core = MinidoracatMiniMapCore
-- ready＝主檔完整走完（版本檢查通過）才為真：拆分前本節位於主檔版本檢查之後，
-- 版本不符時整節不存在——此閘門維持同義行為
if not (Core and Core.ready) then return end

-- 主檔共用成員（皆為主檔載入期一次性賦值的穩定引用；modOptions 無 PZAPI 時為 nil）。
-- 表引用共享同一實例：主檔 registerAnimalGroup/registerZoneAction 等對表的後續插入，
-- 本檔在呼叫時讀到的即最新內容
local modOptions = Core.modOptions
local getBoolOption = Core.getBoolOption
local getComboIndex = Core.getComboIndex
local getSliderValue = Core.getSliderValue
local sandboxGate = Core.sandboxGate
local sandboxDist = Core.sandboxDist
local livestockVisibilityMode = Core.livestockVisibilityMode
local unifiedCsvSet = Core.unifiedCsvSet
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
-- 分類資料：每個分類是一張表，欄位依「標題（主開關）→ 效果預覽 → 開關 → 篩選 →
-- 樣式 → 大小／透明度 → 名稱 → 顯示距離 → 額外 → 重設此分類」的順序畫出；
-- 重設與搜尋索引讀同一份欄位（ticks／chips／combos／sliders／nameTicks／nameSliders／
-- distance），新增選項只改這裡。
--   tick：{ id, label, default, engine?（直寫引擎選項，重設不動）, mpOnly?, gate?（沙盒閘）,
--           livestock?（牲畜模式 4 停用）, shMode?（安全屋沙盒模式 1 停用）, rebuild?, tooltip? }
--   combo：{ id, label, default, items, rebuild? }
--   slider：{ id, label, default, min, max, step, fmt, zeroLabel?, capBy?（伺服器上限＝沙盒選項名） }
-- 值即寫 ModOptions（同步 ESC 頁元件，ModOptions.lua:68-73）並走既有 modOptions:apply()。
--------------------------------------------------------------------------------
local ANIMAL_TICKS = {
    { id = "AnimalWild", label = "UI_MinidoracatMiniMap_AnimalWild", default = false, gate = "AllowAnimalDots" },
    { id = "AnimalLivestock", label = "UI_MinidoracatMiniMap_AnimalLivestock", default = false,
        gate = "AllowAnimalDots", livestock = true },
}
-- 安全屋三件套（範圍框／圖標／名稱）：導覽開關投影三者 OR（同動物母開關）
local SAFEHOUSE_TICKS = {
    { id = "Safehouses", label = "UI_MinidoracatMiniMap_Safehouses", default = true, shMode = "safehouseDisplayMode" },
    { id = "SafehouseIcons", label = "UI_MinidoracatMiniMap_SafehouseIcons", default = true, shMode = "safehouseDisplayMode" },
    { id = "SafehouseNames", label = "UI_MinidoracatMiniMap_SafehouseNames", default = true, shMode = "safehouseNameMode" },
}
-- 顯示距離（格；0＝不限）：與伺服器沙盒距離經 displayDist 取較小者生效。capBy＝對應沙盒
-- 選項名——滑條上限縮到伺服器有效上限（sandboxDist 已併全域上限 AllInfoDistance）、數值寫成
-- 「值／上限」；上限只夾顯示值、不寫回存檔（UI.SliderRow cap 契約）
local DIST_HINT = "UI_MinidoracatMiniMap_DistNote"

local SEC_BASE = { id = "base", label = "UI_MinidoracatMiniMap_SecBase", icon = "layers",
    ticks = {
        -- 圖片化地圖總開關：經 settingsApply → modOptions:apply 觸發雙表面重建/卸載
        { id = "MapImagery", label = "UI_MinidoracatMiniMap_MapImagery", default = true },
        -- 地名開啟會連動強制 Symbols（applyToggleOptions 的耦合）：重建讓引擎勾選跟上
        { id = "PlaceNames", label = "UI_MinidoracatMiniMap_PlaceNames", default = true, rebuild = true },
        { id = "StreetNames", label = "UI_MinidoracatMiniMap_StreetNames", default = true },
        { id = "TextAnnotations", label = "UI_MinidoracatMiniMap_TextAnnotations", default = false },
        { id = "ChunkGrid", label = "UI_MinidoracatMiniMap_ChunkGrid", default = false },
        { id = "ChunkGridLabels", label = "UI_MinidoracatMiniMap_ChunkGridLabels", default = true },
        -- 原版引擎選項（Isometric/Symbols 由原版 saveSettings 跨場存 WorldMapSettings，
        -- ISMiniMap.lua:605-616；RemoteSymbols 原版即不持久化）：不在 ESC、重設不動
        { id = "Isometric", label = "IGUI_MapOption_Isometric", engine = true },
        { id = "Symbols", label = "IGUI_MapOption_Symbols", engine = true },
        { id = "RemoteSymbols", label = "IGUI_MapOption_RemoteSymbols", engine = true },
    },
    sliders = {
        { id = "MapTextScale", label = "UI_MinidoracatMiniMap_MapTextScale",
            default = 100, min = 50, max = 300, step = 10, fmt = "%d%%" },
    },
}
local SEC_PLACES = { id = "places", label = "UI_MinidoracatMiniMap_SecPlaces", icon = "markerFlag",
    ticks = {
        { id = "Players", label = "UI_MinidoracatMiniMap_Players", default = true },
        { id = "RemotePlayers", label = "UI_MinidoracatMiniMap_RemotePlayers", default = true, mpOnly = true },
        -- 家／收藏點標記與陣營分享的目標（旗標＋路線）：地圖上的顯示開關，不影響回家與分享功能
        { id = "Places", label = "UI_MinidoracatMiniMap_Places", default = true },
        { id = "SharedTargets", label = "UI_MinidoracatMiniMap_SharedTargets", default = true, mpOnly = true },
        { id = "NavRoute", label = "UI_MinidoracatMiniMap_NavRoute", default = true },
        { id = "KeepFinishedTrip", label = "UI_MinidoracatMiniMap_KeepFinishedTrip", default = false },
    },
    -- 標記大小（家／收藏、導航旗與行程站、搜尋落點、未分層 addon marker）：繪製端每幀讀值
    sliders = {
        { id = "MarkerIconSize", label = "UI_MinidoracatMiniMap_MarkerIconSize",
            default = 16, min = 8, max = 48, step = 1, fmt = "%dpx" },
    },
}
local SEC_POI = { id = "poicat", label = "UI_MinidoracatMiniMap_SecPOI", icon = "pin",
    -- 母開關只控內部 POI provider（與 ZoneLayer 解耦）
    master = { id = "PoiIcons", label = "UI_MinidoracatMiniMap_PoiIcons", default = true },
    ticks = {
        { id = "PoiBlocks", label = "UI_MinidoracatMiniMap_PoiBlocks", default = false },
        -- 區塊形狀：勾＝整棟一框，不勾＝逐房間矩形（圖標位置不變）
        { id = "PoiWholeBuilding", label = "UI_MinidoracatMiniMap_PoiWholeBuilding", default = true },
        -- 彩色資源點圖標：類別 chip 的小圖跟著換（重建）
        { id = "PoiColorIcons", label = "UI_MinidoracatMiniMap_PoiColorIcons", default = false, rebuild = true },
    },
    sliders = {
        { id = "PoiIconSize", label = "UI_MinidoracatMiniMap_PoiIconSize",
            default = 18, min = 8, max = 48, step = 1, fmt = "%dpx" },
        { id = "PoiIconAlpha", label = "UI_MinidoracatMiniMap_IconAlpha",
            default = 100, min = 10, max = 100, step = 5, fmt = "%d%%" },
    },
    distance = {
        { id = "ClientPoiDisplayDistance", label = "UI_MinidoracatMiniMap_DistPoi",
            default = 0, min = 0, max = 2000, step = 1, fmt = "%d",
            zeroLabel = "UI_MinidoracatMiniMap_DistUnlimited", capBy = "PoiDisplayDistance" },
    },
}
local SEC_ZOMBIE = { id = "zombie", label = "UI_MinidoracatMiniMap_SecZombie", icon = "skull",
    gate = "AllowZombieDots",
    master = { id = "ZombieDots", label = "UI_MinidoracatMiniMap_ZombieDots", default = false, gate = "AllowZombieDots" },
    ticks = {
        -- 世界地圖（M）開關與小地圖獨立；風格/顏色/篩選共用小地圖設定
        { id = "WMZombieDots", label = "UI_MinidoracatMiniMap_WMZombieDots", default = false,
            gate = "AllowZombieDots", tooltip = "UI_MinidoracatMiniMap_WM_tooltip" },
        { id = "ZombieIntensity", label = "UI_MinidoracatMiniMap_ZombieIntensity", default = false },
    },
    combos = {
        { id = "ZombieDotColor", label = "UI_MinidoracatMiniMap_ZombieDotColor", default = 1,
            items = { "UI_MinidoracatMiniMap_ZDotColor_Orange", "UI_MinidoracatMiniMap_ZDotColor_Yellow",
                "UI_MinidoracatMiniMap_ZDotColor_Purple", "UI_MinidoracatMiniMap_ZDotColor_White",
                "UI_MinidoracatMiniMap_ZDotColor_Red" } },
        { id = "ZombieDotMax", label = "UI_MinidoracatMiniMap_ZombieDotMax", default = 2,
            items = { "UI_MinidoracatMiniMap_ZDotMax_100", "UI_MinidoracatMiniMap_ZDotMax_200",
                "UI_MinidoracatMiniMap_ZDotMax_400", "UI_MinidoracatMiniMap_ZDotMax_800" } },
    },
    sliders = {
        { id = "ZombieDotSize", label = "UI_MinidoracatMiniMap_ZombieDotSize",
            default = 3, min = 1, max = 16, step = 1, fmt = "%dpx" },
        { id = "ZombieDotAlpha", label = "UI_MinidoracatMiniMap_IconAlpha",
            default = 100, min = 10, max = 100, step = 5, fmt = "%d%%" },
    },
    distance = {
        { id = "ClientZombieDotDistance", label = "UI_MinidoracatMiniMap_DistZombie",
            default = 0, min = 0, max = 2000, step = 1, fmt = "%d",
            zeroLabel = "UI_MinidoracatMiniMap_DistUnlimited", capBy = "ZombieDotDistance" },
    },
}
local SEC_ANIMALS = { id = "animals", label = "UI_MinidoracatMiniMap_SecAnimals", icon = "pawprint",
    gate = "AllowAnimalDots",
    master = { label = "UI_MinidoracatMiniMap_SecAnimals", members = ANIMAL_TICKS },
    ticks = {
        ANIMAL_TICKS[1], ANIMAL_TICKS[2],
        { id = "WMAnimalWild", label = "UI_MinidoracatMiniMap_WMAnimalWild", default = false,
            gate = "AllowAnimalDots", tooltip = "UI_MinidoracatMiniMap_WM_tooltip" },
        { id = "WMAnimalLivestock", label = "UI_MinidoracatMiniMap_WMAnimalLivestock", default = false,
            gate = "AllowAnimalDots", livestock = true, tooltip = "UI_MinidoracatMiniMap_WM_tooltip" },
    },
    combos = {
        -- 動物圖標風格切換＝物種 chip 小圖跟著換（符號↔彩圖），重建讓玩家立刻看到
        { id = "AnimalIconStyle", label = "UI_MinidoracatMiniMap_AnimalIconStyle", default = 1, rebuild = true,
            items = { "UI_MinidoracatMiniMap_AIconStyle_Symbol", "UI_MinidoracatMiniMap_AIconStyle_Item" } },
        -- 野生色＝野生物種 chip 的染色：跟著重建
        { id = "AnimalWildColor", label = "UI_MinidoracatMiniMap_AnimalWildColor", default = 2, rebuild = true,
            items = ADOTS_COLOR_ITEMS },
        -- 牲畜色＝物種 chip 符號小圖的染色：跟著重建
        { id = "AnimalLivestockColor", label = "UI_MinidoracatMiniMap_AnimalLivestockColor", default = 1, rebuild = true,
            items = ADOTS_COLOR_ITEMS },
    },
    sliders = {
        { id = "AnimalIconSize", label = "UI_MinidoracatMiniMap_AnimalIconSize",
            default = 16, min = 8, max = 48, step = 1, fmt = "%dpx" },
        { id = "AnimalIconAlpha", label = "UI_MinidoracatMiniMap_IconAlpha",
            default = 100, min = 10, max = 100, step = 5, fmt = "%d%%" },
    },
    nameTicks = {
        { id = "AnimalNames", label = "UI_MinidoracatMiniMap_AnimalNames", default = false },
    },
    -- 動物名稱顯示距離（純客戶端，無沙盒 cap）
    nameSliders = {
        { id = "AnimalNameDistance", label = "UI_MinidoracatMiniMap_AnimalNameDistance",
            default = 0, min = 0, max = 2000, step = 1, fmt = "%d",
            zeroLabel = "UI_MinidoracatMiniMap_DistUnlimited" },
    },
    distance = {
        { id = "ClientAnimalIconDistance", label = "UI_MinidoracatMiniMap_DistAnimal",
            default = 0, min = 0, max = 2000, step = 1, fmt = "%d",
            zeroLabel = "UI_MinidoracatMiniMap_DistUnlimited", capBy = "AnimalIconDistance" },
    },
}
local SEC_VEHICLES = { id = "vehicles", label = "UI_MinidoracatMiniMap_SecVehicles", icon = "steeringwheel",
    gate = "AllowVehicleDots",
    master = { id = "VehicleDots", label = "UI_MinidoracatMiniMap_VehicleDots", default = false, gate = "AllowVehicleDots" },
    ticks = {
        { id = "WMVehicleDots", label = "UI_MinidoracatMiniMap_WMVehicleDots", default = false,
            gate = "AllowVehicleDots", tooltip = "UI_MinidoracatMiniMap_WM_tooltip" },
    },
    combos = {
        { id = "VehicleIconColor", label = "UI_MinidoracatMiniMap_VehicleIconColor", default = 4,
            items = ADOTS_COLOR_ITEMS },
    },
    sliders = {
        { id = "VehicleIconSize", label = "UI_MinidoracatMiniMap_VehicleIconSize",
            default = 16, min = 8, max = 48, step = 1, fmt = "%dpx" },
        { id = "VehicleIconAlpha", label = "UI_MinidoracatMiniMap_IconAlpha",
            default = 100, min = 10, max = 100, step = 5, fmt = "%d%%" },
    },
    distance = {
        { id = "ClientVehicleIconDistance", label = "UI_MinidoracatMiniMap_DistVehicle",
            default = 0, min = 0, max = 2000, step = 1, fmt = "%d",
            zeroLabel = "UI_MinidoracatMiniMap_DistUnlimited", capBy = "VehicleIconDistance" },
    },
}
local SEC_SAFEHOUSE = { id = "safehouse", label = "UI_MinidoracatMiniMap_SecSafehouse", icon = "house",
    master = { label = "UI_MinidoracatMiniMap_SecSafehouse", members = SAFEHOUSE_TICKS },
    ticks = SAFEHOUSE_TICKS,
    sliders = {
        { id = "SafehouseIconSize", label = "UI_MinidoracatMiniMap_SafehouseIconSize",
            default = 16, min = 8, max = 48, step = 1, fmt = "%dpx" },
    },
    -- 範圍框／圖標共用 SafehouseDisplayDistance，名稱獨立 SafehouseNameDistance
    distance = {
        { id = "ClientSafehouseDisplayDistance", label = "UI_MinidoracatMiniMap_DistSafehouse",
            default = 0, min = 0, max = 2000, step = 1, fmt = "%d",
            zeroLabel = "UI_MinidoracatMiniMap_DistUnlimited", capBy = "SafehouseDisplayDistance" },
        { id = "ClientSafehouseNameDistance", label = "UI_MinidoracatMiniMap_DistSafehouseName",
            default = 0, min = 0, max = 2000, step = 1, fmt = "%d",
            zeroLabel = "UI_MinidoracatMiniMap_DistUnlimited", capBy = "SafehouseNameDistance" },
    },
}
local SEC_WINDOW = { id = "window", label = "UI_MinidoracatMiniMap_SecWindow", icon = "sliders",
    ticks = {
        { id = "LockPosition", label = "UI_MinidoracatMiniMap_LockPosition", default = false },
        { id = "FreeLook", label = "UI_MinidoracatMiniMap_FreeLook", default = true },
        { id = "ClickOpenWorldMap", label = "UI_MinidoracatMiniMap_ClickOpenWorldMap", default = false },
        { id = "ShowPlayerCoords", label = "UI_MinidoracatMiniMap_ShowPlayerCoords", default = true },
        { id = "GhostMode", label = "UI_MinidoracatMiniMap_GhostMode", default = false },
        -- 勾選經 settingsApply → modOptions:apply()，浮動圖標顯示更新掛在該處
        { id = "FloatIcon", label = "UI_MinidoracatMiniMap_FloatIcon", default = true },
    },
    combos = {
        { id = "MapSize", label = "UI_MinidoracatMiniMap_Size", default = 2,
            items = { "UI_MinidoracatMiniMap_Size_Small", "UI_MinidoracatMiniMap_Size_Medium",
                "UI_MinidoracatMiniMap_Size_Large", "UI_MinidoracatMiniMap_Size_Huge" } },
        { id = "AdornMode", label = "UI_MinidoracatMiniMap_AdornMode", default = 2,
            items = { "UI_MinidoracatMiniMap_AdornMode_Hover", "UI_MinidoracatMiniMap_AdornMode_Always" } },
        { id = "Opacity", label = "UI_MinidoracatMiniMap_Opacity", default = 1,
            items = { "UI_MinidoracatMiniMap_Opacity_Full", "UI_MinidoracatMiniMap_Opacity_Half",
                "UI_MinidoracatMiniMap_Opacity_Faint" } },
    },
    sliders = {
        { id = "GhostAlpha", label = "UI_MinidoracatMiniMap_GhostAlpha",
            default = 40, min = 10, max = 90, step = 5, fmt = "%d%%" },
    },
}
local SEC_PERF = { id = "perf", label = "UI_MinidoracatMiniMap_SecPerf", icon = "chart", noReset = true }
-- 自訂區域（有外部 zone provider 才 present）與 MOD 地圖（有註冊地圖包才 present）：
-- 擴充功能組的內建分類，OnGameBoot 補上 provider 開關、選項與 present 旗標
local SEC_ZONES = { id = "zones", label = "UI_MinidoracatMiniMap_SecZones", icon = "zone",
    group = "addon", order = 1, seq = 0,
    master = { id = "ZoneLayer", label = "UI_MinidoracatMiniMap_ZoneLayer", default = true },
    ticks = {}, -- per-provider 母開關（provider 註冊時給 optionKey 才有）
    sliders = {
        { id = "ZoneIconSize", label = "UI_MinidoracatMiniMap_ZoneIconSize",
            default = 18, min = 8, max = 48, step = 1, fmt = "%dpx" },
    },
    nameTicks = {
        { id = "ZoneNames", label = "UI_MinidoracatMiniMap_ZoneNames", default = true },
        { id = "ZoneNamesFar", label = "UI_MinidoracatMiniMap_ZoneNamesFar", default = true },
    },
    distance = {},
}
local SEC_MAPPACK = { id = "mappack", label = "UI_MinidoracatMiniMap_SecMapPack", icon = "globe",
    group = "addon", order = 2, seq = 0, ticks = {}, combos = {} }
-- 「管理員檢視」分類：三把鑰匙的第三把（玩家自己的本機旗標）唯一的操作面。
-- 分類本身也是三選一才存在——Policy 缺席、玩家沒有 CanSeeAll、或伺服器沒開
-- 戰術政策時整個分類不出現：不合格的玩家連「有這個東西」都不該看到。
-- 三個條件全是 live 值（政策可即時改、權限可被升降、分割畫面每個 slot 各自判定），
-- 每次重建與每幀 live 檢查都現判。
local SEC_ADMIN = { id = "admin", label = "UI_MinidoracatMiniMap_SecAdmin", icon = "shieldCheck" }
local LAYER_SECTIONS = { SEC_BASE, SEC_PLACES, SEC_POI, SEC_ZOMBIE, SEC_ANIMALS, SEC_VEHICLES, SEC_SAFEHOUSE }
local WINDOW_SECTIONS = { SEC_WINDOW, SEC_PERF }

local function adminSectionEligible(pn)
    if not Policy then return false end
    if Policy.hasCanSeeAll(pn) ~= true then return false end
    return Policy.readBool("AllowAdminTacticalView", false) == true
end

local settingsUI -- 單例；獨立頂層視窗，不隨小地圖 Recreate 消失（apply 自行重抓 mm）
-- Addon client 設定區：addon 註冊純資料＋get/set callbacks；值仍由 addon 自己保存。
local addonSettingsById = {}
local addonSectionOrder = {} -- 註冊順序；同 owner 再註冊不重排（seq）

-- 地圖包 addon 專屬選項（有註冊才出現）：OnGameBoot＝所有 MOD lua 載入完
-- （地圖包 require=本 MOD，其註冊呼叫已執行）、且早於 MainOptions 建立——
-- 實際順序 OnGameBoot → OnMainMenuEnter → MainOptions:create →
-- addModOptionsPanel 內 PZAPI.ModOptions:load()（MainOptions.lua:409/2822-2823），
-- 晚追加的選項一樣載得到 ini 存檔值。設定視窗 lazy 建立於遊戲內，同樣晚於此。
Events.OnGameBoot.Add(function()
    if #registeredPacks == 0 or not modOptions then return end
    -- ESC 選項頁：接在主檔「進階」之後，自成「MOD 地圖」一組
    modOptions:addSeparator()
    modOptions:addTitle("UI_MinidoracatMiniMap_SecMapPack")
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
    -- 設定視窗「MOD 地圖」分類（items 與 ESC 頁 addItem 共用同一份表）
    local t, c = SEC_MAPPACK.ticks, SEC_MAPPACK.combos
    t[#t + 1] = { id = "MapPackLayers", label = "UI_MinidoracatMiniMap_MapPackLayers", default = true }
    t[#t + 1] = { id = "MapBounds", label = "UI_MinidoracatMiniMap_MapBounds", default = true }
    c[#c + 1] = { id = "MapBoundsColor", label = "UI_MinidoracatMiniMap_MapBoundsColor", default = 1,
        items = MAPB_COLOR_ITEMS }
    c[#c + 1] = { id = "MapBoundsAlpha", label = "UI_MinidoracatMiniMap_MapBoundsAlpha", default = 1,
        items = MAPB_ALPHA_ITEMS }
    SEC_MAPPACK.present = true
end)

-- Zone 圖層總開關（有「外部」zone provider 註冊才出現；內建 POI 不算——它繞過此閘）
Events.OnGameBoot.Add(function()
    if not hasExternalZoneProvider() or not modOptions then return end
    -- ESC 選項頁：接在最後，自成「自訂區域」一組（PZAPI 無中插 API）
    modOptions:addSeparator()
    modOptions:addTitle("UI_MinidoracatMiniMap_SecZones")
    modOptions:addTickBox("ZoneLayer", "UI_MinidoracatMiniMap_ZoneLayer", true,
        "UI_MinidoracatMiniMap_ZoneLayer_tooltip")
    -- per-provider 母開關（provider 註冊時給了 optionLabelKey 才有）：渲染時
    -- drawZoneFill/Lines/Icons 依 optionKey 讀值，關＝整個 provider 跳過（與 ZoneLayer
    -- 總開關 AND）。家族 Zones addon 自 0.5.0 起不傳（與總開關重複）；機制留給第三方
    -- addon——勿依 provider 數動態隱藏（雙向幽靈，見主檔 registerZoneProvider 契約註解）
    for i = 1, #registeredZoneProviders do
        local p = registeredZoneProviders[i]
        if p.optionKey then
            modOptions:addTickBox(p.optionKey, p.optionLabelKey, true)
            SEC_ZONES.ticks[#SEC_ZONES.ticks + 1] = { id = p.optionKey, label = p.optionLabelKey, default = true }
        end
    end
    -- 名稱遠距開關＋類別篩選 CSV（設定視窗類別 chip 自動寫入；空/'-'＝全開）
    modOptions:addTickBox("ZoneNames", "UI_MinidoracatMiniMap_ZoneNames", true,
        "UI_MinidoracatMiniMap_ZoneNames_tooltip")
    modOptions:addTickBox("ZoneNamesFar", "UI_MinidoracatMiniMap_ZoneNamesFar", true,
        "UI_MinidoracatMiniMap_ZoneNamesFar_tooltip")
    -- 外部自訂區域圖標大小（px，預設 18＝舊版借用 PoiIconSize 時的預設）：_Zones.lua 圖標
    -- pass 對外部 provider 讀此值、內建 POI 仍讀 PoiIconSize
    modOptions:addSlider("ZoneIconSize", "UI_MinidoracatMiniMap_ZoneIconSize", 8, 48, 1, 18)
    -- 自訂區域顯示距離（僅裁外部 provider；渲染端消費見主檔 distGateParams）
    modOptions:addSlider("ClientZoneDisplayDistance", "UI_MinidoracatMiniMap_DistZone", 0, 2000, 1, 0)
    modOptions:addTextEntry("ZoneCategoryFilter", "UI_MinidoracatMiniMap_ZoneCategoryFilter", "",
        "UI_MinidoracatMiniMap_ZoneCategoryFilter_tooltip")
    SEC_ZONES.distance[1] = { id = "ClientZoneDisplayDistance", label = "UI_MinidoracatMiniMap_DistZone",
        default = 0, min = 0, max = 2000, step = 1, fmt = "%d",
        zeroLabel = "UI_MinidoracatMiniMap_DistUnlimited", capBy = "ZoneDisplayDistance" }
    SEC_ZONES.present = true
end)

-- 視窗自己觸發的 apply 期間為真：Core.settingsAfterApply 據此分辨 ESC 頁「套用」
-- （要重建 inspector 同步現值）與視窗內改值（只刷新導覽開關）
local applyingFromWindow = false

local function studioApply()
    if not modOptions then return end
    applyingFromWindow = true
    -- 先 apply 再 save（同原版 MainOptions.lua:3787-3793 順序）：
    -- MapSize 的 apply() 會連帶清空 CustomSize，清除結果必須跟著落地
    local ok, err = pcall(function() if modOptions.apply then modOptions:apply() end end)
    applyingFromWindow = false
    PZAPI.ModOptions:save()
    if not ok then print("[MinidoracatMiniMap] settings apply failed: " .. tostring(err)) end
end

local function settingsApply(entry, value)
    if not modOptions then return end
    local opt = modOptions:getOption(entry.id)
    if not opt then return end
    opt:setValue(value)
    studioApply()
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

-- 篩選 chip 的資料源：items()→{ key, label }；raw＝label 不翻譯（伺服器 zones.json 類別）；
-- get/set 單項、setAll 全選全不選、reset 回預設；icon(it)→Texture|nil, 染色 {r,g,b}|nil（chip 左側
-- 小圖，與地圖同一套貼圖與染色選擇；nil 染色＝原色）。opt＝搜尋與「跳到控制項」的鍵前綴
local function csvChips(opt, items, icon, raw)
    local chips = { opt = opt, items = items, icon = icon, raw = raw }
    function chips.get(it)
        local o = modOptions and modOptions:getOption(opt)
        return not unifiedCsvSet(o and o:getValue() or "")[it.key]
    end
    function chips.set(it, on) unifiedSetFilter(opt, items(), it.key, on) end
    function chips.setAll(list, on) unifiedSetAllFilter(opt, list, on) end
    function chips.reset()
        local o = modOptions and modOptions:getOption(opt)
        if not o then return false end
        o:setValue("-")
        return true
    end
    return chips
end
-- 物種 chip 同時管野生與牲畜；照該物種在地圖上通常的身分染色（預覽的野鹿是野生色，chip 也要一樣）
local WILD_SPECIES = { deer = true, rabbit = true, raccoon = true, rodent = true }
SEC_ANIMALS.chips = csvChips("AnimalSpeciesFilter", function() return ADOTS_SPECIES_UI end, function(def)
    -- 物種小圖與地圖同源（Core.adotsStyleTexture）：物品風格＝彩圖原色；符號風格＝白 glyph 染色
    if not Core.adotsStyleTexture then return nil end
    local tex, asItem = Core.adotsStyleTexture(ADOTS_ART and ADOTS_ART[def.groups[1]],
        getComboIndex("AnimalIconStyle", 1) == 2)
    if asItem or not Core.adotsColor then return tex end
    local c = WILD_SPECIES[def.key] and Core.adotsColor("AnimalWildColor", 2)
        or Core.adotsColor("AnimalLivestockColor", 1)
    return tex, { r = c[1], g = c[2], b = c[3] }
end)
SEC_VEHICLES.chips = csvChips("VehicleCategoryFilter", function() return ADOTS_VEHCAT_UI end)
-- 自訂區域類別是 zones.json 選配欄位——伺服器定義什麼列什麼；MP 區域非同步到貨，資料到了
-- 視窗自動重建（unifiedZoneRefsDirty）。已知取捨：CSV 依「當前可見類別」序列化，已停用但
-- 暫不在清單的類別會被序列化丟出——影響僅「該類別回歸時恢復顯示」
SEC_ZONES.chips = csvChips("ZoneCategoryFilter", function()
    local cats = Core.zoneExternalCategories and Core.zoneExternalCategories() or {}
    local defs = {}
    for i = 1, #cats do defs[i] = { key = cats[i], label = cats[i] } end
    return defs
end, nil, true)
SEC_ZONES.chips.empty = "UI_MinidoracatMiniMap_ZoneNoCats"
-- 資源點 20 類：每類獨立 Cat_<key> 布林選項；POI provider 下一 tick 由簽章偵測到變動重建
SEC_POI.chips = { opt = "Cat",
    items = function()
        local order = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.ORDER
        local cats = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.CATEGORIES
        local out = {}
        if type(order) ~= "table" or type(cats) ~= "table" then return out end
        for i = 1, #order do
            local def = cats[order[i]]
            if def then out[#out + 1] = { key = order[i], label = def.nameKey } end
        end
        return out
    end,
    get = function(it) return getBoolOption("Cat_" .. it.key, true) end,
    set = function(it, on) settingsApply({ id = "Cat_" .. it.key }, on) end,
    setAll = function(list, on)
        if not modOptions then return end
        for i = 1, #list do
            local o = modOptions:getOption("Cat_" .. list[i].key)
            if o then o:setValue(on) end
        end
        studioApply()
    end,
    reset = function()
        local order = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.ORDER
        if not (modOptions and type(order) == "table") then return false end
        for i = 1, #order do
            local o = modOptions:getOption("Cat_" .. order[i])
            if o then o:setValue(true) end
        end
        return true
    end,
    -- 列首類別小圖＝面板即圖例：與地圖同一套貼圖與染色（彩色模式全彩原色；單色或彩圖缺檔時染類別色）
    icon = function(it)
        if not Core.poiIconTexture then return nil end
        local tex, isColor = Core.poiIconTexture(it.key, getBoolOption("PoiColorIcons", false))
        if isColor then return tex end
        local cats = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.CATEGORIES
        local def = type(cats) == "table" and cats[it.key]
        return tex, def and def.color or { r = 0.7, g = 0.7, b = 0.7 }
    end,
}

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

local function addonSliderText(entry, v)
    local ok, s = pcall(string.format, entry.fmt, v)
    if ok and type(s) == "string" then return s end
    return tostring(v)
end
-- test:addon-settings-callbacks:end

--------------------------------------------------------------------------------
-- 狀態判定（inspector、導覽開關、搜尋結果共用同一份）
--------------------------------------------------------------------------------
-- 控制項可否操作：伺服器沙盒閘、牲畜可見性模式 4、安全屋沙盒模式 1
local function entryEnabled(entry, pn)
    if entry.gate and sandboxGate(entry.gate, true, pn) == false then return false end
    if entry.livestock and livestockVisibilityMode(pn) == 4 then return false end
    local modeFn = entry.shMode and Core[entry.shMode]
    if modeFn and modeFn(pn) == 1 then return false end
    return true
end
local function sectionEnabled(sec, pn)
    return not sec.gate or sandboxGate(sec.gate, true, pn) ~= false
end
-- 主開關值：單鍵讀該 option；有 members 者＝成員 OR
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
-- 主開關寫入：members 全部寫成同一值後 apply 一次
local function studioMasterSet(entry, value)
    if not entry.members then return settingsApply(entry, value) end
    if not modOptions then return end
    for i = 1, #entry.members do
        local option = modOptions:getOption(entry.members[i].id)
        if option then option:setValue(value) end
    end
    studioApply()
end

--------------------------------------------------------------------------------
-- 重設此分類：本分類的 ModOptions 寫回預設後 apply＋save；原版引擎選項不動（另做快照還原）
--------------------------------------------------------------------------------
local function studioResetId(id, value)
    if not modOptions then return false end
    local option = modOptions:getOption(id)
    if not option then return false end
    option:setValue(value)
    return true
end

local function studioResetList(list)
    local changed = false
    if not list then return false end
    for i = 1, #list do
        local entry = list[i]
        if not entry.engine and entry.id and entry.default ~= nil then
            if studioResetId(entry.id, entry.default) then changed = true end
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

-- 回 true＝寫了 ModOptions（呼叫端已 apply＋save）
local function studioResetSection(sec, pn)
    if not sec or sec.noReset then return false end
    local changed = false
    if sec.addon then
        local spec = sec.addon
        for i = 1, #spec.ticks do
            local entry = spec.ticks[i]
            -- default nil＝addon 沒宣告預設：不知道該還原成什麼，就不動（v5）
            if entry.default ~= nil then addonWrite(entry, entry.default) end
        end
        for i = 1, #spec.combos do addonWrite(spec.combos[i], spec.combos[i].default or 1) end
        for i = 1, #spec.sliders do addonWrite(spec.sliders[i], spec.sliders[i].default) end
        -- 圖層值由本 MOD 存 MarkerLayers（_Markers 自行 setValue＋apply＋save）
        if #spec.layers > 0 and Core.resetMarkerLayers then Core.resetMarkerLayers(sec.owner) end
        return false
    end
    if sec.id == "admin" then
        -- 只清本機旗標（依 facade 契約連帶清隱私）。刻意不碰沙盒、也不進 apply 路徑：
        -- 這兩個值不在 ModOptions，「重設此分類」更不該把全服政策一起改掉
        if Policy then Policy.setLocalTactical(pn, false) end
        return false
    end
    local master = sec.master
    if master then
        if master.members then changed = studioResetList(master.members)
        elseif studioResetId(master.id, master.default) then changed = true end
    end
    local lists = { sec.ticks, sec.combos, sec.sliders, sec.nameTicks, sec.nameSliders, sec.distance }
    for i = 1, 6 do
        if studioResetList(lists[i]) then changed = true end
    end
    if sec.chips and sec.chips.reset() then changed = true end
    -- 小地圖視窗：拖曳縮放寫入的自訂尺寸一併清掉（同「恢復預設尺寸」）
    if sec.id == "window" and studioResetId("CustomSize", "") then changed = true end
    if changed and modOptions then
        -- apply() 目前只重建／套用 P0，但 reset 可由任一 split-screen 玩家觸發。
        -- 快照所有現存 local mini-map，避免 P2 操作後 P0 的原生 flags 被連帶改寫。
        local engineStates = studioSnapshotEngineStates()
        studioApply()
        studioRestoreEngineStates(engineStates)
    end
    return changed
end

--------------------------------------------------------------------------------
-- 分類組成：四組（地圖圖層／視窗與操作／擴充功能／管理員），群組內建分類順序固定；
-- 擴充與管理員組依 (order, seq) 排，visible(pn) 明確回 false 才藏（拋錯＝顯示、log 一次）
--------------------------------------------------------------------------------
-- test:settings-studio-groups:start
local function addonVisible(sec, pn)
    local fn = sec.addon.visible
    if not fn then return true end
    local ok, v = pcall(fn, pn)
    if not ok then
        if not sec.visibleErrLogged then
            sec.visibleErrLogged = true
            print("[MinidoracatMiniMap] settings section visible() error ("
                .. tostring(sec.id) .. "): " .. tostring(v))
        end
        return true
    end
    return v ~= false
end

-- 插入排序（份數極少）：依 (order, seq)
local function sortSections(list)
    for i = 2, #list do
        local s = list[i]
        local j = i - 1
        while j >= 1 and (list[j].order > s.order or (list[j].order == s.order and list[j].seq > s.seq)) do
            list[j + 1] = list[j]
            j = j - 1
        end
        list[j + 1] = s
    end
end

-- 回 groups（{ title, items }，空組略過）與攤平的分類清單（導覽順序）
local function studioSections(pn)
    local addons, admins = {}, {}
    if SEC_ZONES.present then addons[#addons + 1] = SEC_ZONES end
    if SEC_MAPPACK.present then addons[#addons + 1] = SEC_MAPPACK end
    for i = 1, #addonSectionOrder do
        local sec = addonSectionOrder[i]
        if addonVisible(sec, pn) then
            if sec.group == "admin" then admins[#admins + 1] = sec else addons[#addons + 1] = sec end
        end
    end
    sortSections(addons)
    sortSections(admins)
    if adminSectionEligible(pn) then table.insert(admins, 1, SEC_ADMIN) end
    local groups, flat = {}, {}
    local all = {
        { title = "UI_MinidoracatMiniMap_GroupLayers", items = LAYER_SECTIONS },
        { title = "UI_MinidoracatMiniMap_GroupWindow", items = WINDOW_SECTIONS },
        { title = "UI_MinidoracatMiniMap_GroupAddons", items = addons },
        { title = "UI_MinidoracatMiniMap_GroupAdmin", items = admins },
    }
    for g = 1, #all do
        if #all[g].items > 0 then
            groups[#groups + 1] = all[g]
            for i = 1, #all[g].items do flat[#flat + 1] = all[g].items[i] end
        end
    end
    return groups, flat
end
-- test:settings-studio-groups:end

--------------------------------------------------------------------------------
-- 搜尋：在已翻譯的標籤上做 trim＋lower 的純文字子字串比對；索引項依分類順序
--------------------------------------------------------------------------------
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

-- key＝inspector 控制項的 _findKey（跳到分類後捲到它）
local function studioIndexAdd(index, sec, labelKey, kind, mode, entry, key, raw)
    local label = raw and labelKey or (getTextOrNull(labelKey) or labelKey)
    index[#index + 1] = { sec = sec, label = label, low = label:lower(),
        kind = kind or "navigate", mode = mode, entry = entry, key = key }
end
local function studioIndexEntries(index, sec, list, kind, mode)
    if not list then return end
    for i = 1, #list do
        local e = list[i]
        if not (e.mpOnly and not isClient()) then
            studioIndexAdd(index, sec, e.label, kind, kind == "boolean" and (e.engine and "engine" or mode) or nil,
                e, e.id)
        end
    end
end

local PERF_ITEMS -- 效能說明項目（定義在下方版面段）

local function studioBuildIndex(list)
    local index = {}
    for i = 1, #list do
        local sec = list[i]
        studioIndexAdd(index, sec, sec.label, "category")
        local spec = sec.addon
        if spec then
            studioIndexEntries(index, sec, spec.ticks, "boolean", "addon")
            studioIndexEntries(index, sec, spec.combos, "navigate")
            studioIndexEntries(index, sec, spec.sliders, "navigate")
            studioIndexEntries(index, sec, spec.actions, "navigate")
            for j = 1, #spec.layers do
                studioIndexAdd(index, sec, spec.layers[j].label, "navigate", nil, nil, "layer:" .. spec.layers[j].id)
            end
        elseif sec == SEC_ADMIN then
            -- 只收 navigate：搜尋結果列沒有版面承載「伺服器允許＋主開關已開」這層閘門，
            -- 直接給 checkbox 會做出點了沒反應的開關
            studioIndexAdd(index, sec, "UI_MinidoracatMiniMap_AdminTactical", "navigate")
            studioIndexAdd(index, sec, "UI_MinidoracatMiniMap_AdminPrivacy", "navigate")
        elseif sec == SEC_PERF then
            for j = 1, #PERF_ITEMS do studioIndexAdd(index, sec, PERF_ITEMS[j].name, "navigate") end
        else
            -- 有 members 的主開關，成員本來就在 ticks 裡（同一 option 不給兩顆不同步的 checkbox）
            if sec.master and not sec.master.members then
                studioIndexAdd(index, sec, sec.master.label, "boolean", "mod", sec.master, sec.master.id)
            end
            studioIndexEntries(index, sec, sec.ticks, "boolean", "mod")
            if sec.chips then
                local items = sec.chips.items()
                for j = 1, #items do
                    studioIndexAdd(index, sec, items[j].label, "navigate", nil, nil,
                        sec.chips.opt .. ":" .. items[j].key, sec.chips.raw)
                end
            end
            studioIndexEntries(index, sec, sec.combos, "navigate")
            studioIndexEntries(index, sec, sec.sliders, "navigate")
            studioIndexEntries(index, sec, sec.nameTicks, "boolean", "mod")
            studioIndexEntries(index, sec, sec.nameSliders, "navigate")
            studioIndexEntries(index, sec, sec.distance, "navigate")
            if sec == SEC_WINDOW then
                studioIndexAdd(index, sec, "UI_MinidoracatMiniMap_ResetSize", "navigate", nil, nil, "ResetSize")
            elseif sec == SEC_ZONES then
                for j = 1, #registeredZoneActions do
                    studioIndexAdd(index, sec, registeredZoneActions[j].labelKey, "navigate", nil, nil, "zoneAction:" .. j)
                end
            end
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
local function studioSearchDisabledText(hit, pn)
    if hit.entry.livestock and livestockVisibilityMode(pn) == 4 then
        return getText("UI_MinidoracatMiniMap_LivestockHiddenBySandbox")
    end
    return getText("UI_MinidoracatMiniMap_ServerDisabled")
end

--------------------------------------------------------------------------------
-- 效果預覽（UI.Preview 每幀呼叫 draw(self, x, y, w, h)；self＝預覽元件）：一律呼叫地圖
-- 本身的畫法（Core.drawZombieDot／adotsDrawIcon／drawZoneIcon／drawSafehouseAt／drawPlaceAt／
-- drawMarkerAt），每幀只讀現值；樣本在建窗時備好掛在元件上（self._pv），繪製路徑不配置
-- table／closure。ISUIElement 的 drawRect／drawTextureScaled／drawLine／drawText 都是元件
-- 相對座標（Java 端自加絕對位置），所以地圖 helper 直接以預覽元件當 inner 畫即可。
--------------------------------------------------------------------------------
local PV_ZOMBIE_PTS = { 0.10, 0.30, 0.16, 0.62, 0.22, 0.40, 0.44, 0.66, 0.50, 0.36,
    0.56, 0.58, 0.76, 0.28, 0.82, 0.62, 0.90, 0.44 }
local PV_ZONE_PLAIN = {} -- 預覽用 zone 表（不帶 basement，不觸發提示）
local PV_POI_KEYS = { "military", "medical", "grocery", "gas" }

local function previewZombie(self, x, y, w, h)
    local c = Core.zdotsColor()
    local size = getSliderValue("ZombieDotSize", 3, 1, 16)
    local af = getSliderValue("ZombieDotAlpha", 100, 10, 100) / 100
    for i = 1, #PV_ZOMBIE_PTS, 2 do
        Core.drawZombieDot(self, x + w * PV_ZOMBIE_PTS[i], y + h * PV_ZOMBIE_PTS[i + 1], size, c, af)
    end
end

local function previewAnimals(self, x, y, w, h)
    local styleItem = getComboIndex("AnimalIconStyle", 1) == 2
    local size = getSliderValue("AnimalIconSize", 16, 8, 48)
    local af = getSliderValue("AnimalIconAlpha", 100, 10, 100) / 100
    local wildC = Core.adotsColor("AnimalWildColor", 2)
    local liveC = Core.adotsColor("AnimalLivestockColor", 1)
    local names = getBoolOption("AnimalNames", false)
    local tz = Core.mapTextZoom()
    local nameTh = getTextManager():getFontHeight(UIFont.Small) * tz
    local half = math.floor(size / 2)
    local samples = self._pv
    for i = 1, #samples do
        local a = samples[i]
        local ux = x + w * a.fx - half
        local uy = y + h * 0.36 - half
        local tex, asItem = Core.adotsStyleTexture(a.art, styleItem)
        if tex then
            Core.adotsDrawIcon(self, tex, asItem, ux, uy, size, a.wild and wildC or liveC, a.wild, wildC, af)
        end
        if names then Core.adotsDrawName(self, a.name, ux, uy, half, size, tz, nameTh, af) end
    end
end

local function previewVehicles(self, x, y, w, h)
    local tex = Core.adotsVehTexture()
    if not tex then return end
    local size = getSliderValue("VehicleIconSize", 16, 8, 48)
    local af = getSliderValue("VehicleIconAlpha", 100, 10, 100) / 100
    local c = Core.adotsColor("VehicleIconColor", 4)
    local half = math.floor(size / 2)
    for i = 1, 3 do
        Core.adotsDrawGlyph(self, tex, x + w * i / 4 - half, y + h / 2 - half, size, c[1], c[2], c[3], af)
    end
end

local function previewPoi(self, x, y, w, h)
    local s = getSliderValue("PoiIconSize", 18, 8, 48)
    local ia = getSliderValue("PoiIconAlpha", 100, 10, 100) / 100
    local icons = self._pv
    local n = #icons
    for i = 1, n do
        Core.drawZoneIcon(self, PV_ZONE_PLAIN, icons[i], x + w * i / (n + 1) - s / 2, y + h / 2 - s / 2, s, ia)
    end
end

local function previewSafehouse(self, x, y, w, h)
    local iconSize = getSliderValue("SafehouseIconSize", 16, 8, 48)
    local x1, y1, x2, y2 = x + w * 0.25, y + 4, x + w * 0.75, y + h - 4
    Core.drawSafehouseAt(self, x1, y1, x2, y1, x2, y2, x1, y2, 0.25, 0.95, 0.35,
        getBoolOption("Safehouses", true), getBoolOption("SafehouseIcons", true),
        getBoolOption("SafehouseNames", true) and self._pv or nil, iconSize, Core.mapTextZoom())
end

local function previewPlaces(self, x, y, w, h)
    if not getBoolOption("Places", true) then return end
    local p = self._pv
    local size = Core.markerIconSize()
    local tz = Core.mapTextZoom()
    local lblH = getTextManager():getFontHeight(UIFont.Small) * tz
    local cy = y + h * 0.38
    Core.drawPlaceAt(self, true, x + w * 0.3, cy, size, p.home, p.homeW, tz, lblH)
    Core.drawPlaceAt(self, false, x + w * 0.7, cy, size, p.pin, p.pinW, tz, lblH)
end

local function previewZones(self, x, y, w, h)
    local p = self._pv
    local tz = Core.mapTextZoom()
    local cx, cy = x + w / 2, y + h / 2
    local s = getSliderValue("ZoneIconSize", 18, 8, 48)
    if p.zone then
        Core.drawZoneIcon(self, p.zone, p.zone.icon, cx - s / 2, cy - s / 2 - 8, s,
            getSliderValue("PoiIconAlpha", 100, 10, 100) / 100)
    elseif Core.drawClippedEdge then
        local x1, y1, x2, y2 = x + w * 0.25, y + 4, x + w * 0.75, y + h - 4
        Core.drawClippedEdge(self, x1, y1, x2, y1, 0.6, 0.8, 1, 0.9)
        Core.drawClippedEdge(self, x2, y1, x2, y2, 0.6, 0.8, 1, 0.9)
        Core.drawClippedEdge(self, x2, y2, x1, y2, 0.6, 0.8, 1, 0.9)
        Core.drawClippedEdge(self, x1, y2, x1, y1, 0.6, 0.8, 1, 0.9)
    end
    if getBoolOption("ZoneNames", true) then
        local tw = p.nameW * tz
        local th = getTextManager():getFontHeight(UIFont.Small) * tz
        Core.drawZoneName(self, p.name, cx - tw / 2, p.zone and (cy + s / 2 - 4) or (cy - th / 2), tw, th, tz)
    end
end

-- addon 圖層：用 addon 登記的範例標記，左半＝小地圖、右半＝世界地圖（各自的顯示與名稱開關）
local function previewLayer(self, x, y, w, h)
    local prefs = Core.markerLayer(self._owner, self._layerId)
    local m = self._pv
    if not (prefs and m and m.texture) then return end
    local row = self._sizeRow
    local size = row and row:getValue() or prefs.size
    local tz = Core.mapTextZoom()
    local names = prefs.names
    if prefs.show.mini then
        Core.drawMarkerAt(self, m, x + w * 0.25, y + h / 2, "mini", size,
            (not names or names.mini) and self._label or nil, tz)
    end
    if prefs.show.world then
        Core.drawMarkerAt(self, m, x + w * 0.68, y + h / 2, "world", size,
            (not names or names.world) and self._label or nil, tz)
    end
end

-- 建窗時備樣本（每次重建一次；不在繪製路徑）
local function previewSamples(sec, pv)
    local tm = getTextManager()
    if sec == SEC_ANIMALS then
        local samples = {}
        local want = { { key = "deer", wild = true, fx = 0.3 }, { key = "cow", wild = false, fx = 0.7 } }
        for i = 1, #want do
            local def
            for j = 1, #ADOTS_SPECIES_UI do
                if ADOTS_SPECIES_UI[j].key == want[i].key then def = ADOTS_SPECIES_UI[j] end
            end
            def = def or ADOTS_SPECIES_UI[i]
            if def then
                samples[#samples + 1] = { art = ADOTS_ART and ADOTS_ART[def.groups[1]], wild = want[i].wild,
                    fx = want[i].fx, name = getText(def.label) }
            end
        end
        pv._pv = samples
    elseif sec == SEC_POI then
        local icons = {}
        local cats = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.CATEGORIES
        local colorMode = getBoolOption("PoiColorIcons", false)
        for i = 1, #PV_POI_KEYS do
            local def = type(cats) == "table" and cats[PV_POI_KEYS[i]]
            local tex, isColor
            if def and Core.poiIconTexture then tex, isColor = Core.poiIconTexture(PV_POI_KEYS[i], colorMode) end
            if tex then
                local c = def.color or { r = 0.7, g = 0.7, b = 0.7 }
                icons[#icons + 1] = { tex = tex, r = isColor and 1 or c.r, g = isColor and 1 or c.g,
                    b = isColor and 1 or c.b }
            end
        end
        pv._pv = icons
    elseif sec == SEC_SAFEHOUSE then
        pv._pv = getText("UI_MinidoracatMiniMap_SecSafehouse")
    elseif sec == SEC_PLACES then
        local home = getText("UI_MinidoracatMiniMap_PlaceHome")
        local pin = string.format("%d, %d", 10624, 9856) -- 未命名收藏點＝座標（同 _Places labelOf）
        pv._pv = { home = home, homeW = tm:MeasureStringX(UIFont.Small, home),
            pin = pin, pinW = tm:MeasureStringX(UIFont.Small, pin) }
    elseif sec == SEC_ZONES then
        -- 第一個帶圖標的外部 zone（provider 快取只讀不改）；沒有就畫框＋分類名
        local zone, name
        for i = 1, #registeredZoneProviders do
            local p = registeredZoneProviders[i]
            if not p.internal and not zone then
                local ok, zones = pcall(p.fn)
                if ok and type(zones) == "table" then
                    for j = 1, #zones do
                        local z = rawget(zones, j)
                        if type(z) == "table" and type(z.icon) == "table" and z.icon.tex then
                            zone = z
                            break
                        end
                    end
                end
            end
        end
        name = zone and type(zone.name) == "string" and zone.name ~= "" and zone.name
            or getText("UI_MinidoracatMiniMap_SecZones")
        pv._pv = { zone = zone, name = name, nameW = tm:MeasureStringX(UIFont.Small, name) }
    end
end

local PREVIEWS = {
    [SEC_ZOMBIE] = previewZombie, [SEC_ANIMALS] = previewAnimals, [SEC_VEHICLES] = previewVehicles,
    [SEC_POI] = previewPoi, [SEC_SAFEHOUSE] = previewSafehouse, [SEC_PLACES] = previewPlaces,
    [SEC_ZONES] = previewZones,
}

--------------------------------------------------------------------------------
-- 版面元件：框架元件（Checkbox／Dropdown／SliderRow／Button／Preview）＋一個純繪字的
-- TextBlock（標題、說明段落、分隔線、圖層區塊外框；不可聚焦）。ctx＝單次 inspector 建構
-- 的游標（x／y／w 為 ScrollPanel 內容座標），put() 同時記錄元件供下次重建移除。
--------------------------------------------------------------------------------
local GAP = 6
local LAYER_SIZE = { min = 8, max = 48, step = 1, fmt = "%dpx" } -- addon 圖層大小（MarkerLayers 夾同範圍）
local ORANGE = { r = 0.95, g = 0.55, b = 0.25, a = 1 }
local TextBlock -- ISPanel 子類（第一次建窗時 derive：載入期不依賴原版 ISUI 已載入）

local function textBlockPrerender(self)
    local frame = self._frame
    if frame then
        local Skin = self._skin
        Skin.border(self, 0, 0, self.width, self.height, frame, Skin.shapeOf(self._theme, "control"), 1)
    end
    local rule = self._rule
    if rule then self:drawRect(0, 0, self.width, 1, (rule.a or 1) * 0.5, rule.r, rule.g, rule.b) end
    local lines, c = self._lines, self._color
    if lines then
        for i = 1, #lines do
            self:drawText(lines[i], 0, (i - 1) * self._lineH, c.r, c.g, c.b, c.a or 1, self._font)
        end
    end
    local right = self._right
    if right then
        local rc = self._rightColor
        self:drawText(right, self.width - self._rightW, 0, rc.r, rc.g, rc.b, rc.a or 1, self._font)
    end
end

local function newTextBlock(x, y, w, h)
    if not TextBlock then
        TextBlock = ISPanel:derive("MinidoracatMiniMapSettingsText")
        TextBlock.prerender = textBlockPrerender
    end
    local o = TextBlock:new(x, y, w, h)
    o.background = false
    o:initialise()
    return o
end

local function put(ctx, el)
    ctx.panel:addChild(el)
    local els = ctx.win._inspectorEls
    els[#els + 1] = el
    return el
end
local function advance(ctx, el)
    ctx.y = ctx.y + el.height + GAP
    return el
end

-- 說明段落（UI.Text.wrap 斷行：CJK 禁則與 UTF-16 安全由框架負責）
local function addNote(ctx, text, color, indent)
    indent = indent or 0
    local lines = ctx.UI.Text.wrap(text, ctx.w - indent, UIFont.Small)
    local tb = newTextBlock(ctx.x + indent, ctx.y, ctx.w - indent, math.max(1, #lines) * ctx.lineH)
    tb._lines, tb._font, tb._lineH = lines, UIFont.Small, ctx.lineH
    tb._color = color or ctx.colors.textMuted
    return advance(ctx, put(ctx, tb))
end

-- 一行文字（截字）；回 TextBlock，不推進游標
local function textLine(ctx, x, y, w, text, font, color)
    font = font or UIFont.Small
    local fh = getTextManager():getFontHeight(font)
    local tb = newTextBlock(x, y, w, fh)
    tb._lines, tb._font, tb._lineH = { ctx.UI.Text.fit(text, w, font) }, font, fh
    tb._color = color or ctx.colors.text
    return put(ctx, tb)
end

local function addDivider(ctx)
    local tb = newTextBlock(ctx.x, ctx.y + 2, ctx.w, 4)
    tb._rule = ctx.colors.border
    put(ctx, tb)
    ctx.y = ctx.y + 8
end

local function tooltipFor(entry)
    if entry.tooltip then return getText(entry.tooltip) end
    return getTextOrNull(entry.label .. "_tooltip")
end

local function addCheckbox(ctx, label, checked, onChange, tooltip, indent)
    indent = indent or 0
    local box = ctx.UI.Checkbox.new{ x = ctx.x + indent, y = ctx.y, width = ctx.w - indent, label = label,
        checked = checked == true, target = ctx.win, onChange = onChange, tooltip = tooltip }
    return advance(ctx, put(ctx, box))
end

local function addButton(ctx, title, onClick, tooltip, width, x)
    local btn = ctx.UI.Button.new{ x = x or ctx.x, y = ctx.y, width = width, title = title,
        target = ctx.win, onClick = onClick, tooltip = tooltip }
    return put(ctx, btn)
end

-- 標籤欄＋下拉（UI.Dropdown；options id＝1 起的索引，與 ModOptions combobox 索引同義）
local function addDropdown(ctx, labelText, items, selected, onChange, tooltip)
    local h = ctx.fontH + 10
    textLine(ctx, ctx.x, ctx.y + math.floor((h - ctx.fontH) / 2), ctx.labelW, labelText)
    local options = {}
    for j = 1, #items do options[j] = { id = j, label = getText(items[j]) } end
    local dd = ctx.UI.Dropdown.new{ x = ctx.x + ctx.labelW + 8, y = ctx.y, width = ctx.w - ctx.labelW - 8,
        height = h, options = options, selected = selected, target = ctx.win, onChange = onChange,
        tooltip = tooltip }
    return advance(ctx, put(ctx, dd))
end

local function addSliderRow(ctx, labelText, entry, value, format, onChange, cap, tooltip)
    local row = ctx.UI.SliderRow.new{ x = ctx.x, y = ctx.y, width = ctx.w, label = labelText,
        labelWidth = ctx.labelW, min = entry.min, max = entry.max, step = entry.step, value = value,
        format = format, zeroLabel = entry.zeroLabel and getText(entry.zeroLabel) or nil, cap = cap,
        tooltip = tooltip, target = ctx.win, onChange = onChange }
    return advance(ctx, put(ctx, row))
end

--------------------------------------------------------------------------------
-- 控制項回呼（target＝視窗）。會改版面的變動（重建）一律延到下一幀的視窗 prerender，
-- 不在元件自己的事件處理中途拆掉它
--------------------------------------------------------------------------------
local function studioMarkDirty(win) win._dirty = true end
local function studioNavRefresh(win) if win._nav then win._nav:refresh() end end

-- 標題列主開關與導覽開關同值：改了其一，另一個跟著（inspector 有成員勾選時重建）
local function studioSyncMaster(win, entry)
    local box = win._headerBox
    if box and box._sec and box._sec.master then
        local master = box._sec.master
        local isMember = entry == master
        if master.members then
            for i = 1, #master.members do
                if master.members[i] == entry then isMember = true end
            end
        end
        if isMember then box:setChecked(studioMasterValue(master), true) end
    end
    studioNavRefresh(win)
end

local function onModTick(win, checked, box)
    local entry = box._entry
    if entry.engine then
        unifiedEngineSet(entry.id, checked, win._playerNum or 0)
    else
        settingsApply(entry, checked)
    end
    if entry.rebuild then studioMarkDirty(win) end
    studioSyncMaster(win, entry)
end

local function onModCombo(win, id, dd)
    settingsApply(dd._entry, id)
    if dd._entry.rebuild then studioMarkDirty(win) end
end

-- 內建滑條：拖曳中只寫記憶體值（繪製端每幀讀值＝即時預覽），放開滑鼠才落盤（視窗 prerender
-- 見 _saveDirty；避免拖曳中高頻檔案 IO）。鍵盤／手把一步一寫，同樣在下一幀落盤
local function onModSlider(win, value, row)
    local opt = modOptions and modOptions:getOption(row._entry.id)
    if opt then opt:setValue(value) end -- 同步 ESC 頁元件（ModOptions.lua slider setValue）
    win._saveDirty = true
end

local function onMasterBox(win, checked, box)
    studioMasterSet(box._sec.master, checked)
    studioNavRefresh(win)
    if box._sec.master.members then studioMarkDirty(win) end
end

local function onChip(win, btn)
    local on = not btn:isActive()
    btn._chips.set(btn._chip, on)
    btn:setActive(on)
end
local function onChipsAll(win, btn)
    btn._chips.setAll(btn._items, btn._on)
    studioMarkDirty(win)
end

local function onResetSection(win, btn)
    studioResetSection(btn._sec, win._playerNum or 0)
    studioMarkDirty(win)
    studioNavRefresh(win)
end

-- 恢復預設尺寸：清掉拖曳縮放寫入的 CustomSize，apply 依「自訂尺寸變了」重建小地圖
local function onResetSize(win)
    settingsApply({ id = "CustomSize" }, "")
end

local function onAddonTick(win, checked, box) addonWrite(box._entry, checked == true) end
local function onAddonCombo(win, id, dd) addonWrite(dd._entry, id) end
local function onAddonSlider(win, value, row) addonWrite(row._entry, value) end
-- action 按鈕：把視窗擁有者 pn 交給 run/enabled；enabled 回 false 不跑；run 拋錯只留一則診斷
local function onAddonAction(win, btn)
    local entry = btn._entry
    if type(entry) ~= "table" or type(entry.run) ~= "function" then return end
    local pn = win._playerNum or 0
    if not addonActionEnabled(entry, pn) then return end
    local ok, err = pcall(entry.run, pn)
    if not ok then print("[MinidoracatMiniMap] addon action failed: " .. addonErrorText(err)) end
end

-- addon 圖層（v5）：值寫進本 MOD 的 MarkerLayers（Core.setMarkerLayer 自行 apply＋save；
-- 標成視窗自己的 apply，免得 settingsAfterApply 把它當 ESC 套用而整頁重建）
local function studioSetLayer(owner, id, field, value)
    if not Core.setMarkerLayer then return end
    applyingFromWindow = true
    pcall(Core.setMarkerLayer, owner, id, field, value)
    applyingFromWindow = false
end
local function onLayerBox(win, checked, box)
    studioSetLayer(box._owner, box._layerId, box._field, checked)
end
-- 大小滑條拖曳中只記待寫值，放開滑鼠才 setMarkerLayer（每次寫都落盤）；預覽讀滑條現值
local function onLayerSize(win, value, row)
    row._pending = value
    win._layerPending = row
end
local function studioFlushLayer(win)
    local row = win._layerPending
    win._layerPending = nil
    if row and row._pending then
        studioSetLayer(row._owner, row._layerId, "size", row._pending)
        row._pending = nil
    end
end

local function onAdminTactical(win, checked)
    if Policy then Policy.setLocalTactical(win._playerNum or 0, checked == true) end
    studioMarkDirty(win) -- setter 回的是實際存下的值：重建讓勾選彈回真值
end
local function onAdminPrivacy(win, checked)
    if Policy then Policy.setLocalPrivacy(win._playerNum or 0, checked == true) end
    studioMarkDirty(win)
end

local function onZoneActionPick(win, id, dd) dd._action._selected = id end
local function onZoneAction(win, btn)
    local action = btn._action
    local opt = action.options and action.options[btn._dropdown and btn._dropdown:getSelected() or 1]
    action.onTrigger(opt and opt.value)
end

--------------------------------------------------------------------------------
-- inspector 各段
--------------------------------------------------------------------------------
local function addHeader(ctx, sec)
    local mh = getTextManager():getFontHeight(UIFont.Medium)
    local h = math.max(mh, 24)
    local master = sec.master
    textLine(ctx, ctx.x, ctx.y + math.floor((h - mh) / 2), ctx.w - (master and 48 or 0),
        getText(sec.label), UIFont.Medium, ctx.colors.accent)
    if master then
        local box = ctx.UI.Checkbox.new{ x = ctx.x + ctx.w - 40, y = ctx.y + math.floor((h - 20) / 2),
            width = 40, height = 20, label = "", checked = studioMasterValue(master), target = ctx.win,
            onChange = onMasterBox, tooltip = getText(master.label) }
        box._sec = sec
        box:setEnabled(sectionEnabled(sec, ctx.pn) and (master.members ~= nil or entryEnabled(master, ctx.pn)))
        put(ctx, box)
        ctx.win._headerBox = box
    end
    ctx.y = ctx.y + h + GAP
    if sec.gate and not sectionEnabled(sec, ctx.pn) then
        addNote(ctx, getText("UI_MinidoracatMiniMap_ServerDisabled"), ORANGE)
    end
end

local function addPreview(ctx, sec, draw, h)
    local pv = ctx.UI.Preview.new{ x = ctx.x, y = ctx.y, width = ctx.w, height = h or ctx.previewH, draw = draw }
    previewSamples(sec, pv)
    return advance(ctx, put(ctx, pv))
end

local function addTicks(ctx, sec, list)
    if not list then return end
    for i = 1, #list do
        local entry = list[i]
        if not (entry.mpOnly and not isClient()) then
            local checked
            if entry.engine then checked = unifiedEngineGet(entry.id, ctx.pn)
            else checked = getBoolOption(entry.id, entry.default) end
            local box = addCheckbox(ctx, getTextOrNull(entry.label) or entry.id, checked, onModTick,
                tooltipFor(entry))
            box._entry, box._findKey = entry, entry.id
            box:setEnabled(entryEnabled(entry, ctx.pn))
        end
    end
end

local function addChips(ctx, chips)
    local items = chips.items()
    if #items == 0 then
        if chips.empty then addNote(ctx, getText(chips.empty)) end
        return
    end
    local h = ctx.fontH + 8
    local x, y = ctx.x, ctx.y
    -- 框架 rev 17 buttonIconColor：chip 小圖照地圖染色；較早的 rev 17 build 沒有這個旗標＝原色
    local canTint = ctx.UI.CAPABILITIES.buttonIconColor == true
    for i = 1, #items do
        local it = items[i]
        local tex, tint
        if chips.icon then tex, tint = chips.icon(it) end
        local btn = ctx.UI.Button.new{ x = x, y = y, height = h, title = chips.raw and it.label or getText(it.label),
            icon = tex, iconColor = canTint and tint or nil, style = "chip", active = chips.get(it),
            target = ctx.win, onClick = onChip }
        if x > ctx.x and x + btn.width > ctx.x + ctx.w then
            x, y = ctx.x, y + h + 4
            btn:setX(x)
            btn:setY(y)
        end
        btn._chips, btn._chip, btn._findKey = chips, it, chips.opt .. ":" .. it.key
        put(ctx, btn)
        x = x + btn.width + 4
    end
    ctx.y = y + h + GAP
    local half = math.floor((ctx.w - 4) / 2)
    local all = addButton(ctx, getText("UI_MinidoracatMiniMap_SelectAll"), onChipsAll, nil, half)
    all._chips, all._items, all._on = chips, items, true
    local none = addButton(ctx, getText("UI_MinidoracatMiniMap_SelectNone"), onChipsAll, nil, half, ctx.x + half + 4)
    none._chips, none._items, none._on = chips, items, false
    advance(ctx, all)
end

local function addCombos(ctx, list)
    if not list then return end
    for i = 1, #list do
        local entry = list[i]
        local dd = addDropdown(ctx, getText(entry.label), entry.items, getComboIndex(entry.id, entry.default), onModCombo)
        dd._entry, dd._findKey = entry, entry.id
    end
end

local function entryFormat(entry)
    local f = entry._format
    if not f then
        f = function(v) return string.format(entry.fmt, v) end
        entry._format = f
    end
    return f
end

local function addSliders(ctx, list)
    if not list then return end
    local pn = ctx.pn
    for i = 1, #list do
        local entry = list[i]
        -- capBy＝伺服器沙盒距離選項：SliderRow 每幀問上限函式（含全域上限 AllInfoDistance）
        local cap, tip
        if entry.capBy and sandboxDist then
            cap = function() return sandboxDist(entry.capBy, pn) end
            tip = getText(DIST_HINT)
        end
        local row = addSliderRow(ctx, getText(entry.label), entry,
            getSliderValue(entry.id, entry.default, entry.min, entry.max), entryFormat(entry),
            onModSlider, cap, tip)
        row._entry, row._findKey = entry, entry.id
    end
end

local function addResetButton(ctx, sec)
    ctx.y = ctx.y + 4
    local text = getText("UI_MinidoracatMiniMap_StudioResetCategory")
    local w = math.min(ctx.w, math.max(120, getTextManager():MeasureStringX(UIFont.Small, text) + 24))
    local btn = addButton(ctx, text, onResetSection,
        getText("UI_MinidoracatMiniMap_StudioResetCategory_tooltip"), w, ctx.x + ctx.w - w)
    btn._sec = sec
    advance(ctx, btn)
end

-- 註冊的 zone 動作列（registerZoneAction，如 Zones addon 的「生成區域範本」）：[下拉]+[按鈕]
local function addZoneActions(ctx)
    for ai = 1, #registeredZoneActions do
        local action = registeredZoneActions[ai]
        local title = getText(action.labelKey)
        local tip = action.tooltipKey and getText(action.tooltipKey) or nil
        local dd
        local btnW = ctx.w
        if action.options then
            btnW = math.max(80, math.min(getTextManager():MeasureStringX(UIFont.Small, title) + 24, ctx.w - 130))
            local options = {}
            for j = 1, #action.options do options[j] = { id = j, label = getText(action.options[j].labelKey) } end
            dd = ctx.UI.Dropdown.new{ x = ctx.x, y = ctx.y, width = ctx.w - btnW - 4, height = ctx.fontH + 10,
                options = options, selected = action._selected or 1, target = ctx.win, onChange = onZoneActionPick }
            dd._action = action
            put(ctx, dd)
        end
        local btn = addButton(ctx, title, onZoneAction, tip, btnW, ctx.x + ctx.w - btnW)
        btn._action, btn._dropdown, btn._findKey = action, dd, "zoneAction:" .. ai
        if dd then btn:setHeight(dd.height) end
        advance(ctx, btn)
    end
end

local function addNotes(ctx, sec)
    if sec == SEC_ANIMALS and livestockVisibilityMode(ctx.pn) == 4 then
        addNote(ctx, getText("UI_MinidoracatMiniMap_LivestockHiddenBySandbox"), ORANGE)
    elseif sec == SEC_SAFEHOUSE then
        local rectMode = Core.safehouseDisplayMode and Core.safehouseDisplayMode(ctx.pn) or 3
        local nameMode = Core.safehouseNameMode and Core.safehouseNameMode(ctx.pn) or 3
        if rectMode == 1 or nameMode == 1 then
            addNote(ctx, getText(rectMode == 1 and "UI_MinidoracatMiniMap_SafehouseHiddenBySandbox"
                or "UI_MinidoracatMiniMap_SafehouseNamesHiddenBySandbox"), ORANGE)
        end
    end
end

-- 內建分類：標題 → 預覽 → 開關 → 篩選 → 樣式 → 大小／透明度 → 名稱 → 顯示距離 → 額外 → 重設
local function buildSection(ctx, sec)
    addHeader(ctx, sec)
    if PREVIEWS[sec] then addPreview(ctx, sec, PREVIEWS[sec]) end
    addTicks(ctx, sec, sec.ticks)
    addNotes(ctx, sec)
    if sec.chips then addChips(ctx, sec.chips) end
    addCombos(ctx, sec.combos)
    addSliders(ctx, sec.sliders)
    addTicks(ctx, sec, sec.nameTicks)
    addSliders(ctx, sec.nameSliders)
    addSliders(ctx, sec.distance)
    if sec == SEC_WINDOW then
        local text = getText("UI_MinidoracatMiniMap_ResetSize")
        local btn = addButton(ctx, text, onResetSize, getText("UI_MinidoracatMiniMap_ResetSize_tooltip"))
        btn._findKey = "ResetSize"
        advance(ctx, btn)
    elseif sec == SEC_ZONES then
        addZoneActions(ctx)
    end
    addResetButton(ctx, sec)
end

-- addon 圖層區塊（v5）：外框內＝圖層名＋顯示開關（小地圖）→ 預覽 → 世界地圖也顯示 →
-- 大小 8–48 px →（有名稱時）兩張地圖的名稱開關；值全走 Core.setMarkerLayer
local function addLayerBlock(ctx, sec, layer)
    local prefs = Core.markerLayer and Core.markerLayer(sec.owner, layer.id)
    if not prefs then return end
    local frame = newTextBlock(ctx.x, ctx.y, ctx.w, 10)
    frame._frame, frame._skin, frame._theme = ctx.colors.border, ctx.UI.Skin, ctx.win.theme
    put(ctx, frame)
    local x0, w0 = ctx.x, ctx.w
    ctx.x, ctx.w = ctx.x + 8, ctx.w - 16
    ctx.y = ctx.y + 8
    local function layerBox(box, field)
        box._owner, box._layerId, box._field = sec.owner, layer.id, field
        return box
    end
    local h = 24
    local label = getText(layer.label)
    textLine(ctx, ctx.x, ctx.y + math.floor((h - ctx.fontH) / 2), ctx.w - 48, label)
    local sw = ctx.UI.Checkbox.new{ x = ctx.x + ctx.w - 40, y = ctx.y + 2, width = 40, height = 20, label = "",
        checked = prefs.show.mini, target = ctx.win, onChange = onLayerBox, tooltip = label }
    sw._findKey = "layer:" .. layer.id
    put(ctx, layerBox(sw, "showMini"))
    ctx.y = ctx.y + h + GAP
    local pv
    if type(layer.sample) == "table" then
        pv = addPreview(ctx, sec, previewLayer)
        pv._pv, pv._owner, pv._layerId = layer.sample, sec.owner, layer.id
        local sl = layer.sample.label
        pv._label = type(sl) == "string" and sl ~= "" and (getTextOrNull(sl) or sl) or nil
    end
    layerBox(addCheckbox(ctx, getText("UI_MinidoracatMiniMap_WorldAlso"), prefs.show.world, onLayerBox), "showWorld")
    local row = addSliderRow(ctx, getText("UI_MinidoracatMiniMap_LayerSize"),
        LAYER_SIZE, prefs.size, entryFormat(LAYER_SIZE), onLayerSize)
    row._owner, row._layerId = sec.owner, layer.id
    if pv then pv._sizeRow = row end
    if prefs.names then
        layerBox(addCheckbox(ctx, getText(layer.namesMiniLabel or "UI_MinidoracatMiniMap_LayerNamesMini"),
            prefs.names.mini, onLayerBox), "namesMini")
        layerBox(addCheckbox(ctx, getText(layer.namesWorldLabel or "UI_MinidoracatMiniMap_LayerNamesWorld"),
            prefs.names.world, onLayerBox), "namesWorld")
    end
    frame:setHeight(ctx.y + 2 - frame.y)
    ctx.x, ctx.w = x0, w0
    ctx.y = ctx.y + 2 + GAP
end

-- test:addon-settings-builder:start
local function buildAddon(ctx, sec)
    local spec = sec.addon
    addHeader(ctx, sec)
    for i = 1, #spec.layers do addLayerBlock(ctx, sec, spec.layers[i]) end
    for i = 1, #spec.ticks do
        local entry = spec.ticks[i]
        local box = addCheckbox(ctx, getText(entry.label), addonRead(entry.get, entry.default == true) == true,
            onAddonTick, entry.tooltip and getText(entry.tooltip) or nil)
        box._entry = entry
    end
    for i = 1, #spec.combos do
        local entry = spec.combos[i]
        local items = entry.items
        local default = entry.default or 1
        local selected = addonRead(entry.get, default)
        if type(selected) ~= "number" or selected ~= selected or selected < 1 or selected > #items then
            selected = default
        end
        local dd = addDropdown(ctx, getText(entry.label), items, selected - selected % 1, onAddonCombo,
            entry.tooltip and getText(entry.tooltip) or nil)
        dd._entry = entry
    end
    for i = 1, #spec.sliders do
        local entry = spec.sliders[i]
        local value = addonRead(entry.get, entry.default)
        if type(value) ~= "number" or value ~= value then value = entry.default end
        -- 量化（以 min 為基準）與夾值由框架 Slider 負責；值換格才回呼＝才寫 addon
        local row = addSliderRow(ctx, getText(entry.label), entry, value,
            function(v) return addonSliderText(entry, v) end, onAddonSlider,
            nil, entry.tooltip and getText(entry.tooltip) or nil)
        row._entry = entry
    end
    for i = 1, #spec.actions do
        local entry = spec.actions[i]
        local btn = addButton(ctx, getText(entry.label), onAddonAction, getText(entry.tooltip), ctx.w)
        btn._entry = entry
        btn:setEnabled(addonActionEnabled(entry, ctx.pn))
        advance(ctx, btn)
    end
    addResetButton(ctx, sec)
end
-- test:addon-settings-builder:end

local function buildAdmin(ctx, sec)
    addHeader(ctx, sec)
    if not Policy then return end
    local pn = ctx.pn
    addNote(ctx, getText("UI_MinidoracatMiniMap_AdminNote"))
    local tacticalOn = Policy.localTactical(pn) == true
    local tactical = addCheckbox(ctx, getText("UI_MinidoracatMiniMap_AdminTactical"), tacticalOn,
        onAdminTactical, getText("UI_MinidoracatMiniMap_AdminTactical_tooltip"))
    tactical._findKey = "AdminTactical"
    -- 隱私層是戰術層的子開關：版面用縮排表達依賴，行為由 enable 釘住——伺服器
    -- 沒開第二把政策鑰匙、或戰術層還沒打開，都不可勾（勾了 setter 也會回 false）
    local privacyAllowed = Policy.readBool("AllowAdminPrivacyView", false) == true
    local privacy = addCheckbox(ctx, getText("UI_MinidoracatMiniMap_AdminPrivacy"),
        Policy.localPrivacy(pn) == true, onAdminPrivacy,
        getText("UI_MinidoracatMiniMap_AdminPrivacy_tooltip"), 20)
    privacy:setEnabled(privacyAllowed and tacticalOn)
    if not privacyAllowed then
        addNote(ctx, getText("UI_MinidoracatMiniMap_AdminPrivacyDisabled"), ORANGE, 20)
    end
    addResetButton(ctx, sec)
end

-- 效能說明：逐項「名稱（白）＋等級（彩色右對齊）」標題列＋縮排描述（懸掛式）。等級色沿
-- 家族 Okabe-Ito 色盲友善向（綠／黃／橘）。等級是機制推導＋整包實測錨點（2026-09-30 B42.21.0
-- GameProfiler A/B 各 3 輪：資源點／殭屍／動物／載具圖標全開＋0.38ms/幀 ≈ 60fps 幀預算 2.3%，
-- 文案取整約 0.4ms／約 2％）——無逐項 profiler 數據，不給逐項百分比（數字表述紀律）。
-- 資源點標「中」：拉到整張地圖入鏡時它是小地圖的主要成本。文案寫給一般玩家。
local PERF_LEVELS = {
    [0] = { key = "UI_MinidoracatMiniMap_PerfLv0", r = 0.40, g = 0.80, b = 0.40, a = 1 },
    [1] = { key = "UI_MinidoracatMiniMap_PerfLv1", r = 0.90, g = 0.85, b = 0.35, a = 1 },
    [2] = { key = "UI_MinidoracatMiniMap_PerfLv2", r = 0.95, g = 0.60, b = 0.25, a = 1 },
}
PERF_ITEMS = {
    { name = "UI_MinidoracatMiniMap_PerfItemMap", lvl = 0, desc = "UI_MinidoracatMiniMap_PerfDescMap" },
    { name = "UI_MinidoracatMiniMap_PerfItemPoi", lvl = 2, desc = "UI_MinidoracatMiniMap_PerfDescPoi" },
    { name = "UI_MinidoracatMiniMap_PerfItemZone", lvl = 1, desc = "UI_MinidoracatMiniMap_PerfDescZone" },
    { name = "UI_MinidoracatMiniMap_PerfItemZombie", lvl = 2, desc = "UI_MinidoracatMiniMap_PerfDescZombie" },
    { name = "UI_MinidoracatMiniMap_PerfItemAnimal", lvl = 1, desc = "UI_MinidoracatMiniMap_PerfDescAnimal" },
    { name = "UI_MinidoracatMiniMap_PerfItemMisc", lvl = 1, desc = "UI_MinidoracatMiniMap_PerfDescMisc" },
    -- 42.21 起街名每幀逐字 Translator 重排（E2E：預設 zoom 19 約 0.2-0.5ms/幀，拉遠由主檔縮放閘門停畫）
    { name = "UI_MinidoracatMiniMap_PerfItemStreet", lvl = 1, desc = "UI_MinidoracatMiniMap_PerfDescStreet" },
    { name = "UI_MinidoracatMiniMap_PerfItemChunk", lvl = 1, desc = "UI_MinidoracatMiniMap_PerfDescChunk" },
}
local PERF_NOTES = { "UI_MinidoracatMiniMap_PerfNoteWorldmap", "UI_MinidoracatMiniMap_PerfGame",
    "UI_MinidoracatMiniMap_PerfDebug" }

local function buildPerf(ctx, sec)
    addHeader(ctx, sec)
    addNote(ctx, getText("UI_MinidoracatMiniMap_PerfIntro"))
    addNote(ctx, getText("UI_MinidoracatMiniMap_PerfZoom"))
    addDivider(ctx)
    local tm = getTextManager()
    for i = 1, #PERF_ITEMS do
        local item = PERF_ITEMS[i]
        local lv = PERF_LEVELS[item.lvl]
        local title = textLine(ctx, ctx.x, ctx.y, ctx.w, getText(item.name))
        title._right, title._rightColor = getText(lv.key), lv
        title._rightW = tm:MeasureStringX(UIFont.Small, title._right)
        title._findKey = item.name
        advance(ctx, title)
        addNote(ctx, getText(item.desc), nil, 12)
        if i < #PERF_ITEMS then addDivider(ctx) end
    end
    addDivider(ctx)
    -- 世界地圖、遊戲選項（螢幕外介面渲染／介面渲染幀率）、-debug：各一段，都不是本 MOD 的開關
    for i = 1, #PERF_NOTES do addNote(ctx, getText(PERF_NOTES[i])) end
    -- 收尾行動建議提亮（整區唯一的「該做什麼」）
    addNote(ctx, getText("UI_MinidoracatMiniMap_PerfAdvice"), ctx.colors.text)
end

--------------------------------------------------------------------------------
-- 搜尋結果：布林項直接給開關（受伺服器閘門與牲畜模式限制），其餘是跳到分類的按鈕
--------------------------------------------------------------------------------
local function studioSelect(win, id, findKey)
    win._selectedSec = id
    win._page = "inspector"
    win._scrollToKey = findKey
    if win._query ~= "" then
        win._search:setText("")
        win._query = ""
    end
    studioMarkDirty(win)
end

local function onSearchTick(win, checked, box)
    local hit = box._hit
    local pn = win._playerNum or 0
    if hit.mode == "engine" then
        unifiedEngineSet(hit.entry.id, checked, pn)
    elseif hit.mode == "addon" then
        addonWrite(hit.entry, checked == true)
    else
        if hit.entry == hit.sec.master then studioMasterSet(hit.entry, checked)
        else settingsApply(hit.entry, checked) end
        if hit.entry.rebuild then studioMarkDirty(win) end
    end
    studioNavRefresh(win)
end
local function onSearchNavigate(win, btn)
    studioSelect(win, btn._hit.sec.id, btn._hit.key)
end
local function onBack(win)
    win._page = "nav"
    if win._query ~= "" then
        win._search:setText("")
        win._query = ""
    end
    studioMarkDirty(win)
end

local function buildResults(ctx, hits)
    if #hits == 0 then
        addNote(ctx, getText("UI_MinidoracatMiniMap_StudioNoResults"))
        return
    end
    for i = 1, #hits do
        local hit = hits[i]
        local text = getText(hit.sec.label) .. " / " .. hit.label
        if hit.kind == "boolean" then
            local enabled = hit.mode == "addon" or entryEnabled(hit.entry, ctx.pn)
            if not enabled then text = text .. " - " .. studioSearchDisabledText(hit, ctx.pn) end
            local box = addCheckbox(ctx, text, studioBoolValue(hit, ctx.pn), onSearchTick)
            box._hit = hit
            box:setEnabled(enabled)
        else
            local btn = addButton(ctx, text, onSearchNavigate, nil, ctx.w)
            btn._hit = hit
            advance(ctx, btn)
        end
    end
end

--------------------------------------------------------------------------------
-- 版面量測與 pane：導覽寬＝最長分類名＋圖示＋開關；inspector 車道寬＝各語系標籤實測
--（夾 [340, 480]）；放不下兩欄就單頁（導覽或 inspector 二選一，inspector 帶「返回分類」）
--------------------------------------------------------------------------------
-- test:settings-studio-layout:start
local function studioPaneLayout(viewportW, inspectorW, navW)
    local available = math.max(1, math.floor(viewportW or 0) - 8)
    if navW + inspectorW + 24 <= available then
        return { mode = "wide", navW = navW, inspectorW = inspectorW, windowW = navW + inspectorW + 24 }
    end
    local w = math.min(available, math.max(navW, inspectorW) + 16)
    return { mode = "narrow", navW = w - 16, inspectorW = w - 16, windowW = w }
end
-- test:settings-studio-layout:end

local function studioMeasure(list, fontH)
    local tm = getTextManager()
    local function tw(key) return tm:MeasureStringX(UIFont.Small, getTextOrNull(key) or key) end
    local navW = fontH * 11
    local tickW, labelW = 0, 0
    local function ticks(l)
        if not l then return end
        for i = 1, #l do tickW = math.max(tickW, tw(l[i].label)) end
    end
    local function labels(l)
        if not l then return end
        for i = 1, #l do labelW = math.max(labelW, tw(l[i].label)) end
    end
    for i = 1, #list do
        local sec = list[i]
        navW = math.max(navW, tw(sec.label) + 30 + (sec.master and 48 or 0) + 16)
        local spec = sec.addon or sec
        ticks(spec.ticks)
        ticks(spec.nameTicks)
        labels(spec.combos)
        labels(spec.sliders)
        labels(spec.nameSliders)
        labels(spec.distance)
    end
    local laneW = math.max(340, tickW + 44 + 8, labelW + 180)
    if laneW > 480 then laneW = 480 end
    return navW + 12, laneW, math.min(labelW, math.floor(laneW * 0.45))
end

--------------------------------------------------------------------------------
-- 視窗：UI.Window（只有關閉鈕）＋搜尋 TextField＋左側 NavList（ScrollPanel）＋右側
-- inspector（ScrollPanel）。開窗＝重建（同步 ESC 頁改過的值）；開著時只在搜尋字、分類
-- 成員、沙盒／政策、zone 資料變動或控制項要求時，於下一幀 prerender 重建。
--------------------------------------------------------------------------------
local function studioNavGroups(win, groups)
    local out = {}
    for g = 1, #groups do
        local items = {}
        for i = 1, #groups[g].items do
            local sec = groups[g].items[i]
            local item = { id = sec.id, label = getText(sec.label), icon = sec.icon }
            local master = sec.master
            if master then
                item.switch = {
                    get = function() return studioMasterValue(master) end,
                    set = function(v)
                        studioMasterSet(master, v)
                        if win._selectedSec == sec.id then studioMarkDirty(win) end
                    end,
                    enabled = function()
                        local pn = win._playerNum or 0
                        return sectionEnabled(sec, pn) and (master.members ~= nil or entryEnabled(master, pn))
                    end,
                }
            end
            items[i] = item
        end
        out[g] = { title = getText(groups[g].title), items = items }
    end
    return out
end

local function studioFindEl(win, key)
    local els = win._inspectorEls
    for i = 1, #els do
        if els[i]._findKey == key then return els[i] end
    end
    return nil
end

local function studioFillInspector(win, sec, hits, showBack)
    local UI, panel = win._UI, win._inspector
    if win._shownKey then win._scrollBy[win._shownKey] = panel:getYScroll() end
    local els = win._inspectorEls
    for i = 1, #els do panel:removeChild(els[i]) end
    win._inspectorEls = {}
    win._headerBox = nil
    local fontH = getTextManager():getFontHeight(UIFont.Small)
    local ctx = { win = win, UI = UI, panel = panel, pn = win._playerNum or 0,
        x = 8, y = 8, w = math.max(1, panel:contentWidth() - 16), labelW = win._labelW,
        fontH = fontH, lineH = fontH + 2, previewH = math.max(64, fontH * 2 + 40),
        colors = win.theme.colors }
    if showBack then
        advance(ctx, addButton(ctx, getText("UI_MinidoracatMiniMap_StudioBack"), onBack))
    end
    local key
    if hits then
        key = "__search"
        buildResults(ctx, hits)
    else
        key = sec.id
        if sec.addon then buildAddon(ctx, sec)
        elseif sec == SEC_ADMIN then buildAdmin(ctx, sec)
        elseif sec == SEC_PERF then buildPerf(ctx, sec)
        else buildSection(ctx, sec) end
    end
    -- 內容高先自己設好（ScrollPanel 下一幀 prerender 才量），捲動位置才夾得對
    panel:setScrollHeight(math.max(ctx.y + 4, panel.height))
    local target = win._scrollToKey and studioFindEl(win, win._scrollToKey)
    win._scrollToKey = nil
    if target then
        panel:setYScroll(0)
        panel:scrollTo(target)
    else
        panel:setYScroll(win._scrollBy[key] or 0)
    end
    win._shownKey = key
end

local function studioRebuild(win)
    win._dirty = nil
    local UI = win._UI
    local pn = win._playerNum or 0
    studioFlushLayer(win)
    UI.Dropdown.close(win)
    local groups, list = studioSections(pn)
    local ids = {}
    for i = 1, #list do ids[i] = list[i].id end
    local sig = table.concat(ids, ",")
    if sig ~= win._sig then
        win._sig = sig
        win._index = studioBuildIndex(list)
        win._nav:setGroups(studioNavGroups(win, groups))
    end
    local sec = list[1]
    for i = 1, #list do
        if list[i].id == win._selectedSec then sec = list[i] end
    end
    win._selectedSec = sec.id
    win._nav:refresh()
    -- 版面
    local fontH = getTextManager():getFontHeight(UIFont.Small)
    local navW, laneW, labelW = studioMeasure(list, fontH)
    win._labelW = labelW
    local viewportW, viewportH = getPlayerScreenWidth(pn), getPlayerScreenHeight(pn)
    local sx, sy = getPlayerScreenLeft(pn), getPlayerScreenTop(pn)
    local pane = studioPaneLayout(viewportW, laneW + 28, navW)
    local titleH = win:titleBarHeight()
    local searchH = fontH + 10
    local bodyY = titleH + 8 + searchH + 8
    -- 視窗底的下限：從小地圖開＝小地圖外框底（原版快捷列就在它下面，視窗底與它齊平），
    -- 世界地圖開＝viewport 底（留 8px）。放不下就縮內容區（兩欄各自捲動），但至少留 8 列高
    -- （viewport 本身更矮時以 viewport 為準）——這時視窗會低過小地圖底
    local floorY, gap = sy + viewportH, 8
    local mini = win._fromMini and getPlayerMiniMap(pn)
    if mini then
        -- 按鈕列「滑鼠懸停時」模式收合時外框不含按鈕列：補回它的高（原版收合也替它留位，
        -- ISMiniMap.lua:539-540），重建時視窗才不會跟著上下跳
        local bottom = mini:getAbsoluteY() + mini:getHeight()
        local bp = mini.bottomPanel
        if bp and not bp:isVisible() then bottom = bottom + bp:getHeight() + 1 end
        floorY, gap = math.min(floorY, bottom), 0
    end
    win._floorY = floorY
    local bodyH = math.max(80, math.min(math.max(540, (fontH + 8) * 24), floorY - gap - sy - bodyY - 8),
        math.min((fontH + 8) * 8, viewportH - bodyY - 16))
    win._pane = pane.mode
    win:setWidth(pane.windowW)
    win:setHeight(bodyY + bodyH + 8)
    win._search:setX(8)
    win._search:setY(titleH + 8)
    win._search:setWidth(math.max(1, pane.windowW - 16))
    local hits = studioQuery(win._index, win._query)
    local showInspector = pane.mode == "wide" or hits ~= nil or win._page == "inspector"
    local showNav = pane.mode == "wide" or not showInspector
    -- 單頁的分類清單不標選取：點目前分類也要觸發 onSelect（NavList 只在選取改變時回呼）
    win._nav:setSelected(showInspector and sec.id or nil, true)
    local navScroll, inspector = win._navScroll, win._inspector
    navScroll:setVisible(showNav)
    inspector:setVisible(showInspector)
    if showNav then
        navScroll:setX(8)
        navScroll:setY(bodyY)
        navScroll:setWidth(pane.navW)
        navScroll:setHeight(bodyH)
        win._nav:setWidth(navScroll:contentWidth())
    end
    if showInspector then
        inspector:setX(showNav and (pane.navW + 16) or 8)
        inspector:setY(bodyY)
        inspector:setWidth(pane.inspectorW)
        inspector:setHeight(bodyH)
        studioFillInspector(win, sec, hits, pane.mode == "narrow")
    end
    -- 開著時重建後夾回：不低於視窗底下限、不出該玩家 viewport
    if win:isVisible() then
        local x, y = win:getX(), win:getY()
        if x + win.width > sx + viewportW then x = sx + viewportW - win.width end
        if x < sx then x = sx end
        if y + win.height > floorY then y = floorY - win.height end
        if y < sy then y = sy end
        win:setX(x)
        win:setY(y)
    end
end

-- 自訂區域資料到貨時的視窗自動刷新：zone 快取是原子替換（C2 契約：provider 恆回快取參照、
-- 更新即換新表），參照變＝資料變：逐外部 provider 比參照，變了才重建。每幀成本＝外部
-- provider 數次 pcall（fn 只回參照，純 Lua）＋等值比較；provider 拋錯記為 false
local function unifiedZoneRefsDirty(win)
    local refs = win._zoneRefs
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

-- 沙盒閘、牲畜模式、政策 revision 與管理員資格的 live signature（距離上限由 SliderRow 自己每幀問）
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
    -- policy revision＝沙盒值或本機旗標的變動計數；role eligibility 另需逐幀
    -- 輪詢——管理員被升／降權不經任何寫入路徑，revision 不會動，只能直接比資格
    local rev = Policy and Policy.getRevision() or 0
    local admin = adminSectionEligible(pn)
    if win._liveRev ~= rev or win._liveAdmin ~= admin then dirty = true end
    win._liveRev, win._liveAdmin = rev, admin
    return dirty
end
-- test:settings-studio-live:end

local function studioSave(win)
    win._saveDirty = nil
    if PZAPI and PZAPI.ModOptions then PZAPI.ModOptions:save() end
end

local function studioPrerender(self)
    if unifiedZoneRefsDirty(self) then
        self._sig = nil -- 區域類別也在搜尋索引裡
        self._dirty = true
    end
    if studioLiveSettingsDirty(self) then self._dirty = true end
    local mouseDown = isMouseButtonDown and isMouseButtonDown(0)
    if not mouseDown then
        if self._saveDirty then studioSave(self) end
        if self._layerPending then studioFlushLayer(self) end
    end
    if self._dirty then
        local ok, err = pcall(studioRebuild, self)
        if ok then
            self._rebuildErrLogged = nil
        else
            self._dirty = true -- 下一幀重試
            if not self._rebuildErrLogged then
                self._rebuildErrLogged = true
                print("[MinidoracatMiniMap] settings rebuild failed, retrying: " .. tostring(err))
            end
        end
    end
    self._UI.Window.prerender(self)
end

-- 顯示／隱藏：框架 Window 顯示時固定為 player 0 接手把（Window.lua onShown）；分割畫面的
-- 擁有者可能是別人，這裡改成擁有者本人在用手把才接手（原版先例 ISMiniMap.lua:595-597），
-- 隱藏時還原原焦點（手把 B＝Focus 關窗，原焦點＝小地圖外框，ISMiniMap.lua:173-177 同義）
local function studioSetVisible(self, visible)
    local was = self.javaObject ~= nil and self:getIsVisible()
    ISPanel.setVisible(self, visible)
    if was == (visible == true) then return end
    local Focus = self._UI.Focus
    if not Focus then return end
    if visible then
        Focus.onFocus(self)
        local pn = self._playerNum or 0
        if JoypadState and JoypadState.players[pn + 1] then Focus.takeJoypad(self, pn) end
    else
        Focus.releaseJoypad(self)
        Focus.clear(self)
    end
end

local function studioOnClose(win)
    if win._saveDirty then studioSave(win) end
    studioFlushLayer(win)
    win._UI.Dropdown.close(win)
    -- 手把玩家關窗：原焦點已不在畫面上時（Focus 還給角色＝nil），回到自己的小地圖
    local pn = win._playerNum or 0
    if JoypadState and JoypadState.players[pn + 1] and getJoypadFocus and getJoypadFocus(pn) == nil then
        local mm = getPlayerMiniMap(pn)
        if mm and mm:isReallyVisible() then setJoypadFocus(pn, mm) end
    end
end

local function onSearchChange(field, text)
    local win = field._win
    local q = studioNormalizeQuery(text)
    if q ~= win._query then
        win._query = q
        studioMarkDirty(win)
    end
end

local function onNavSelect(win, id)
    studioSelect(win, id)
end

local function studioCreate(UI)
    local win = UI.Window.new{ x = 0, y = 0, width = 600, height = 400, icon = "sliders",
        title = getText("UI_MinidoracatMiniMap_StudioTitle"), onClose = studioOnClose }
    win._UI = UI
    win.setVisible = studioSetVisible
    win.prerender = studioPrerender
    win._inspectorEls, win._scrollBy, win._zoneRefs = {}, {}, {}
    win._selectedSec, win._page, win._query, win._playerNum = SEC_BASE.id, "nav", "", 0
    win:setVisible(false)
    win:addToUIManager()
    local search = UI.TextField.new{ x = 8, y = win:titleBarHeight() + 8, width = 300,
        placeholder = getText("UI_MinidoracatMiniMap_StudioSearchHint"), clearButton = true,
        onChange = onSearchChange }
    search._win = win
    win._search = search
    win:addChild(search)
    win._navScroll = UI.ScrollPanel.new{ width = 200, height = 200 }
    win:addChild(win._navScroll)
    win._nav = UI.NavList.new{ width = 180, groups = {}, target = win, onSelect = onNavSelect }
    win._navScroll:addChild(win._nav)
    win._inspector = UI.ScrollPanel.new{ width = 300, height = 200 }
    win:addChild(win._inspector)
    unifiedZoneRefsDirty(win) -- 播種參照快照（避免首幀誤判 dirty 多重建一次）
    studioLiveSettingsDirty(win)
    return win
end

-- 框架探測：設定視窗需要 rev 17 的全部元件；缺任一就不開新視窗（地圖本身照常 fail-soft）
-- test:settings-studio-framework:start
local function studioFramework()
    local UI = MinidoracatUI and MinidoracatUI.v1
    if not (UI and UI.API_MAJOR == 1 and type(UI.API_REVISION) == "number" and UI.API_REVISION >= 17) then
        return nil
    end
    local c = UI.CAPABILITIES
    if c and c.window and c.controls and c.dropdown and c.scrollPanel and c.textWrap
            and c.navList and c.sliderRow and c.preview and c.controlTooltips then
        return UI
    end
    return nil
end

-- 每按一次提示一次：框架有 Toast 用 Toast，否則玩家頭上的提示字
local function studioNeedFramework(pn)
    local text = getText("UI_MinidoracatMiniMap_NeedFramework")
    local UI = MinidoracatUI and MinidoracatUI.v1
    if UI and UI.CAPABILITIES and UI.CAPABILITIES.toast and UI.Toast
            and pcall(UI.Toast.show, { title = getText("UI_MinidoracatMiniMap_Options"), message = text }) then
        return
    end
    local player = getSpecificPlayer(pn)
    if player and HaloTextHelper then HaloTextHelper.addBadText(player, text) end
end
-- test:settings-studio-framework:end

local function toggleSettingsWindow(outer)
    local pn = outer and outer.playerNum or 0
    local UI = studioFramework()
    if not UI then
        studioNeedFramework(pn)
        return
    end
    if not settingsUI then settingsUI = studioCreate(UI) end
    local win = settingsUI
    local wasVisible = win:isVisible()
    if wasVisible then
        -- 同一位玩家再按＝關閉，但視窗被世界地圖蓋住時看不見：改走下方重建重定位＋置頂，一按就出現
        -- （Core.isBehindWorldMap 在 _Search.lua）。不同玩家按（分割畫面：世界地圖單例／各自小地圖
        -- 都會轉呼此處）＝改掛新擁有者重建重定位，而不是把前一位的視窗關掉——
        -- 否則 P2 第一按只會關 P1 的窗，或直接沿用 P1 身分讀寫引擎選項
        if win._playerNum == pn and not (Core.isBehindWorldMap and Core.isBehindWorldMap(win, pn)) then
            win:close()
            return
        end
        if win._playerNum ~= pn and UI.Focus then UI.Focus.releaseJoypad(win) end
    end
    win._playerNum = pn -- 視窗擁有者（分割畫面各自讀寫自己的小地圖）
    win._fromMini = outer ~= nil and outer.inner ~= nil -- 小地圖外框（ISMiniMapOuter）才有 inner；世界地圖沒有
    win._sig = nil      -- 分類成員依擁有者判定（管理員資格、addon visible(pn)）
    studioLiveSettingsDirty(win)
    studioRebuild(win) -- 開窗即重建＝同步現值（可能在 ESC 選項頁被改過）
    -- 靠小地圖（或世界地圖）左側：小地圖＝底與小地圖外框底齊平，世界地圖＝頂與地圖頂齊平；夾進該玩家 viewport
    local sx, sy = getPlayerScreenLeft(pn), getPlayerScreenTop(pn)
    local sw = getPlayerScreenWidth(pn)
    local x = (outer and outer.getAbsoluteX and outer:getAbsoluteX() or sx) - win.width - 8
    local y = outer and outer.getAbsoluteY and outer:getAbsoluteY() or sy
    if win._fromMini then y = win._floorY - win.height end
    if x < sx then x = sx end
    if x + win.width > sx + sw then x = sx + sw - win.width end
    if y + win.height > win._floorY then y = win._floorY - win.height end
    if y < sy then y = sy end
    win:setX(x)
    win:setY(y)
    win:setVisible(true)
    if wasVisible and UI.Focus and JoypadState and JoypadState.players[pn + 1] then
        UI.Focus.takeJoypad(win, pn) -- 已開著時換擁有者：setVisible 不會再觸發接手
    end
    win:bringToTop()
end
-- 主檔開窗入口（小地圖齒輪 onButton4 wrap／世界地圖爪印鈕）呼叫時查表＋nil 防呆
Core.toggleSettingsWindow = toggleSettingsWindow
-- 外部改動引擎選項後的視窗刷新（小地圖視角鈕等）：視窗開著且屬同玩家才重建——
-- 關著/他人視窗不動（開窗本就重建、他人視窗讀的是他自己的小地圖）
Core.refreshSettingsWindow = function(pn)
    if settingsUI and settingsUI:isVisible() and settingsUI._playerNum == (pn or 0) then
        studioRebuild(settingsUI)
    end
end
-- 主檔 modOptions:apply() 尾端呼叫：視窗自己觸發的 apply 只刷新導覽開關；ESC 頁「套用」
-- 改了值＝下一幀重建 inspector（控制項重讀現值）
Core.settingsAfterApply = function()
    local win = settingsUI
    if not (win and win:isVisible()) then return end
    studioNavRefresh(win)
    if not applyingFromWindow then studioMarkDirty(win) end
end
-- 測試與 E2E 的觀測面（不是公開 API）：視窗、導覽、inspector、搜尋欄、目前分類、
-- 目前顯示的控制項清單與分類 id 清單；selectSection(id[, findKey]) 立即切分類並重建
Core.settingsWindow = function()
    local win = settingsUI
    if not win then return nil end
    local ids = {}
    local _, list = studioSections(win._playerNum or 0)
    for i = 1, #list do ids[i] = list[i].id end
    return {
        win = win, nav = win._nav, navScroll = win._navScroll, inspector = win._inspector,
        search = win._search, selected = win._selectedSec, controls = win._inspectorEls,
        sections = ids, pane = win._pane,
        find = function(key) return studioFindEl(win, key) end,
        selectSection = function(id, findKey)
            studioSelect(win, id, findKey)
            studioRebuild(win)
        end,
        rebuild = function() studioRebuild(win) end,
    }
end

-- 公開 addon client-settings API（版本見 settingsApiVersion）。ownerModId 是唯一身分：同 owner 重註冊
-- 視為熱重載更新，不同 addon 即使自選同名 label 也不互相覆蓋。外部 spec
-- 在註冊期完整驗證並複製；壞值 fail closed，不得把整個 MiniMap 設定窗炸掉。
-- 導覽列只顯示分類名稱與圖標，不讀取、保存或計算摘要／數量 callback。
-- test:addon-settings-registry:start
local function normalizeAddonSettings(ownerModId, spec)
    if type(ownerModId) ~= "string" or ownerModId == ""
            or type(spec) ~= "table" or type(spec.label) ~= "string"
            or spec.label == "" then return nil end
    -- API v1 相容：舊呼叫端可繼續傳 spec.lane，但地圖顯示設定不讀、不正規化、
    -- 不複製也不保存它。v2 另複製 actions（最多 16）；v3 另收選用 visible(pn)
    -- （見 addonSectionSync）；v4 另複製 sliders（最多 32）；v5 另收 icon／group／order
    -- （側欄圖標與分組排序）與 layers（marker 圖層，值由本 MOD 存 MarkerLayers）。
    if spec.visible ~= nil and type(spec.visible) ~= "function" then return nil end
    local icon, group, order = spec.icon, spec.group, spec.order
    if icon == nil then icon = "plug" elseif type(icon) ~= "string" or icon == "" then return nil end
    if group == nil then group = "addon" elseif type(group) ~= "string" then return nil end
    if group ~= "admin" then group = "addon" end
    if order == nil then order = 100
    elseif type(order) ~= "number" or order ~= order or order == math.huge
            or order == -math.huge then return nil end
    local out = { label = spec.label, ticks = {}, combos = {}, sliders = {}, actions = {},
        layers = {}, visible = spec.visible, icon = icon, group = group, order = order }
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
        -- default 缺＝nil（v5）：「重設此分類」略過，不再把未宣告預設的勾選寫成 false
        out.ticks[i] = { label = e.label, tooltip = e.tooltip,
            default = e.default, get = e.get, set = e.set }
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
    local sliders = spec.sliders
    if sliders ~= nil and type(sliders) ~= "table" then return nil end
    local sliderN = sliders and #sliders or 0
    if sliderN > 32 then return nil end
    for i = 1, sliderN do
        local e = sliders[i]
        if type(e) ~= "table" then return nil end
        local lo, hi, step = e.min, e.max, e.step
        -- 有限數：NaN（自身不等）與 ±inf 都拒收
        if type(e.label) ~= "string" or e.label == ""
                or type(e.get) ~= "function" or type(e.set) ~= "function"
                or (e.tooltip ~= nil and type(e.tooltip) ~= "string")
                or (e.fmt ~= nil and type(e.fmt) ~= "string")
                or type(lo) ~= "number" or lo ~= lo or lo == math.huge or lo == -math.huge
                or type(hi) ~= "number" or hi ~= hi or hi == math.huge
                or type(step) ~= "number" or step ~= step
                or lo >= hi or step <= 0 or step > hi - lo then return nil end
        local default = e.default
        if default == nil then default = lo end
        if type(default) ~= "number" or default < lo or default > hi then return nil end
        if default < hi then -- 對齊格點（同 addonSliderSnap；max 不在格點上時仍可為 default）
            default = lo + math.floor((default - lo) / step + 0.5) * step
            if default > hi then default = hi end
        end
        -- 數值格式：預設整數範圍用 "%d"、否則兩位小數；在真 runtime 試格式化兩端，
        -- 拋錯或結果超過 24 字（數值標放不下）整個 spec 拒收
        local fmt = e.fmt
        if fmt == nil then fmt = (lo % 1 == 0 and step % 1 == 0) and "%d" or "%.2f" end
        local okLo, sLo = pcall(string.format, fmt, lo)
        local okHi, sHi = pcall(string.format, fmt, hi)
        if not okLo or not okHi or type(sLo) ~= "string" or type(sHi) ~= "string"
                or #sLo > 24 or #sHi > 24 then return nil end
        out.sliders[i] = { label = e.label, tooltip = e.tooltip, min = lo, max = hi,
            step = step, default = default, fmt = fmt, get = e.get, set = e.set }
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
    -- v5 layers：最多 8 層、id 在 spec 內唯一；壞值整個 spec 拒收。owner 不得含 MarkerLayers
    -- 序列化的分隔字元（; = ,），否則存值會被讀錯成別層
    local layers = spec.layers
    if layers ~= nil and type(layers) ~= "table" then return nil end
    local layerN = layers and #layers or 0
    if layerN > 8 or (layerN > 0 and ownerModId:find("[;=,]")) then return nil end
    local seen = {}
    for i = 1, layerN do
        local e = layers[i]
        if type(e) ~= "table" or type(e.id) ~= "string" or not e.id:match("^[%w_%-]+$")
                or seen[e.id] or type(e.label) ~= "string" or e.label == ""
                or (e.show ~= nil and type(e.show) ~= "table")
                or (e.names ~= nil and type(e.names) ~= "table")
                or (e.sample ~= nil and type(e.sample) ~= "table") then return nil end
        local size = e.size
        if size == nil then size = 16 end
        if type(size) ~= "number" or size % 1 ~= 0 or size < 8 or size > 48 then return nil end
        local labels = { e.namesMiniLabel, e.namesWorldLabel }
        for j = 1, 2 do
            if labels[j] ~= nil and (type(labels[j]) ~= "string" or labels[j] == "") then return nil end
        end
        -- show／names 的 mini、world：缺＝true，非布林拒收
        local flags = { true, true, true, true }
        local src = { e.show and e.show.mini, e.show and e.show.world,
            e.names and e.names.mini, e.names and e.names.world }
        for j = 1, 4 do
            if src[j] ~= nil then
                if type(src[j]) ~= "boolean" then return nil end
                flags[j] = src[j]
            end
        end
        seen[e.id] = true
        out.layers[i] = { id = e.id, label = e.label, size = size,
            show = { mini = flags[1], world = flags[2] },
            names = e.names and { mini = flags[3], world = flags[4] } or nil,
            namesMiniLabel = e.namesMiniLabel, namesWorldLabel = e.namesWorldLabel,
            sample = e.sample }
    end
    return out
end

-- v5：settingsApiVersion 5＝icon／group／order／layers、tick default 缺＝nil；
-- v4：sliders；v3：spec.visible(pn)；v2：actions
MinidoracatMiniMapAPI.settingsApiVersion = 5
function MinidoracatMiniMapAPI.registerSettingsSection(ownerModId, spec)
    local normalized = normalizeAddonSettings(ownerModId, spec)
    if not normalized then
        print("[MinidoracatMiniMap] registerSettingsSection bad arguments: "
            .. tostring(ownerModId))
        return false
    end
    local sec = addonSettingsById[ownerModId]
    if sec then
        sec.label = normalized.label
        sec.addon = normalized
        sec.visibleErrLogged = nil -- 新 visible 的錯誤值得記一次新 log
    else
        -- seq＝註冊序（同 order 時的排序鍵，再註冊沿用）
        sec = { id = "addon_" .. ownerModId, label = normalized.label, addon = normalized,
            owner = ownerModId, seq = #addonSectionOrder + 1 }
        addonSettingsById[ownerModId] = sec
        addonSectionOrder[#addonSectionOrder + 1] = sec
    end
    sec.icon, sec.group, sec.order = normalized.icon, normalized.group, normalized.order
    -- marker 圖層預設值交給 _Markers（載入序在本檔之前；缺＝圖層照 v2 畫）
    if Core and Core.registerMarkerLayers then Core.registerMarkerLayers(ownerModId, normalized.layers) end
    if settingsUI then
        settingsUI._sig = nil -- 成員或標籤變了：導覽與搜尋索引一起重建
        if settingsUI:isVisible() then studioMarkDirty(settingsUI) end
    end
    return true
end
-- test:addon-settings-registry:end

Events.OnGameStart.Add(function()
    if settingsUI then
        settingsUI._UI.Dropdown.close(settingsUI)
        settingsUI:setVisible(false)
        settingsUI:removeFromUIManager()
        settingsUI = nil
    end
end)
