-- MinidoracatMiniMapPOICategories.lua
-- room name → 14 類 POI 分類 + 每類調色盤，純資料表（主 MOD 內建 POI）。
-- 分類邏輯留在本檔（Rust 渲染端只出 raw geometry）；重新分類＝改本檔，改完重跑
-- scripts/gen_poi_data.py 重新烘焙 MinidoracatMiniMapPOIData.lua。
--
-- color = { r, g, b }（0-1）：14 色可辨識調色盤，同時用於圖標上色與區塊填色/框線。
-- ORDER：ModOptions 類別勾選與統一視窗類別格的穩定顯示順序（CATEGORIES 是 hash）。
--
-- 資料來源：D:/SteamLibrary/steamapps/common/ProjectZomboid/media/lua/server/Items/
-- Distributions.lua 的 distributionTable 頂層 room key（小寫 room key 是
-- loot 權威）。room name 若只以別名形式存在（SuburbsDistributions.lua 的
-- SuburbsDistributions.<alias> = SuburbsDistributions.<canonical> 重導向），
-- 一併列入——.lotheader 裡的實際 room name 可能就是別名拼法。
--
-- 逐鍵查核記錄（2026-07-17，對照上述兩檔）：
--   armystorage/armysurplus：Distributions.lua 頂層 room key 皆存在。
--   policeoffice/policestorage/policegunstorage：皆存在。
--   gunstore/gunstorestorage：皆存在。
--   hospitalroom/medical/medicaloffice：Distributions.lua 頂層皆存在；
--     clinic：不是頂層 key，但 SuburbsDistributions.lua:156 有別名
--     `clinic = medical`，視為合法 room name 一併收錄。
--     medclinic：SuburbsDistributions.lua:177 別名 `medclinic = medical`，一併收錄
--     （2026-07-18 codex review 抓漏：raw 中 16 棟含 medclinic，漏收致 3 棟消失）。
--   pharmacy：存在。
--   firestorage/firegarage：皆存在。
--   library/bookstore：皆存在。
--   classroom/elementaryschool：皆存在。elementaryhall：SuburbsDistributions.lua:162
--     別名 `elementaryhall = elementaryschool`，一併收錄（2026-07-18 codex review 抓漏：
--     raw 中 10 棟含 elementaryhall，漏收致 7 棟錯分 medical、3 棟消失）。
--   grocery/gigamart/conveniencestore/grocerystorage：皆存在。
--   fossoil/gas2go/gasstore/gasstorage：皆存在。
--   toolstore/mechanic/carsupply：皆存在；toolstorage：非頂層 key，
--     SuburbsDistributions.lua:188 別名 `toolstorage = toolstorestorage`，
--     故一併收錄別名拼法 toolstorage 與其指向的真實頂層 key toolstorestorage。
--   outdoorsupply/camping/hunting/sportstore/sportstorage：皆存在。
--   prisoncells：Distributions.lua 頂層存在；cells：非頂層 key，
--     SuburbsDistributions.lua:155 別名 `cells = prisoncells`，一併收錄。
--   rangeroffice/rangerstorage：Distributions.lua 有 loot 表，但 42.19 全圖 .lotheader
--     實掃 0 棟建物含此 room（當時 poi_raw.json 8541 棟查核）——ranger 類別無資料可顯示，
--     已整類移除（原第 15 類；2026-07-18 codex review 抓出空類別）。
--     2026-07-30 更新：42.20 新圖出現 1 棟護林站 (4663,8591) 28x15，含 rangerhall/
--     rangerlocker/rangerstorage/office_ranger/garage_ranger；因同棟含 medical 房間，
--     現以 medical 類顯示。全圖僅此 1 棟，維持不恢復 ranger 類（刻意取捨——恢復需
--     同步改 gen_poi_data.py 的 EXPECTED_CATEGORY_COUNT/CATEGORY_PRIORITY 並補圖標）。
--   warehouse/storageunit：皆存在。
--   armytent（:3966，公路軍事檢查哨帳篷）→ military；
--   oldarmy（:12935，March Ridge 地下軍事地堡）→ military；
--   oldmedical（:12965，同地堡醫療區）→ medical。
--   bunker（無 Distributions loot 表，但實際地圖存在：(5575,9363) 3x13 lv-1 隱藏
--   生存者地堡，玩家高價值）→ military。POI 價值以「位置存在」為準，非 loot 表。
--
-- 42.20 storage 系補洞（2026-07-30，對照 42.20 Distributions.lua 頂層 key＋
-- poi_raw.json 9254 棟實掃）：police/fire/gas/grocery/sport/army 的 storage 變體
-- 原本都收了，本次補齊同家族缺漏——
--   Distributions 頂層 key 且圖上有實體：medicalstorage(28 棟)/hospitalstorage(5)/
--     pharmacystorage(28)/campingstorage(7)/schoolstorage(12)/schoolgymstorage(12)/
--     policelocker(10)/policearchive(3)/prisonstorage(4)/prisonlaundry(4)/
--     gymstorage(8)/universitystorage(1)。
--   非 loot key、依 bunker「位置存在」前例收錄：gunstorage(7 棟，含 Muldraugh
--     (11024,9431) 與 (2454..2513, 10944-10945) 一排 5 棟淨新)/bookstorage(5 棟)/
--     universityclassroom(3 棟，大學園區三棟大樓)。
--   其餘同家族 key（prisonlocker/swatlocker/bookstorestorage 等）：其建物已由
--     既有 key 落入同一類別，收錄與否不改變 POI 數，故不收。
--   刻意不收（無對應類別可歸）：loggingwarehouse(3 棟)/seafoodkitchen(6 棟)——
--     未來若擴充餐飲/伐木類別再議。
--   注意：新 key 落在較高優先級類別時會從既有類別「接手」建物（本波 medical
--     53→48、grocery 101→97、storage 82→81），屬主身分修正而非資料遺失；
--     總數 606→636 淨增 30 筆。
-- ⚠ CATEGORIES 各 entry 內不要插註解行——scripts/gen_poi_data.py 以 regex 解析
--   nameKey/rooms 相鄰結構，entry 內註解會使該類別解析失敗而整類消失。

MinidoracatMiniMapPOICategories = MinidoracatMiniMapPOICategories or {}

MinidoracatMiniMapPOICategories.CATEGORIES = {
    military = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Military",
        rooms = { "armystorage", "armysurplus", "armytent", "oldarmy", "bunker" },
        color = { r = 0.42, g = 0.45, b = 0.20 },
    },
    police = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Police",
        rooms = { "policeoffice", "policestorage", "policegunstorage", "policelocker", "policearchive" },
        color = { r = 0.20, g = 0.42, b = 0.85 },
    },
    gunstore = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Gunstore",
        rooms = { "gunstore", "gunstorestorage", "gunstorage" },
        color = { r = 0.55, g = 0.12, b = 0.14 },
    },
    medical = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Medical",
        rooms = { "hospitalroom", "medical", "medicaloffice", "clinic", "medclinic", "oldmedical", "medicalstorage", "hospitalstorage" },
        color = { r = 0.90, g = 0.22, b = 0.28 },
    },
    pharmacy = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Pharmacy",
        rooms = { "pharmacy", "pharmacystorage" },
        color = { r = 0.10, g = 0.68, b = 0.42 },
    },
    fire = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Fire",
        rooms = { "firestorage", "firegarage" },
        color = { r = 0.95, g = 0.48, b = 0.12 },
    },
    books = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Books",
        rooms = { "library", "bookstore", "bookstorage" },
        color = { r = 0.15, g = 0.58, b = 0.66 },
    },
    school = {
        nameKey = "UI_MinidoracatMiniMap_Cat_School",
        rooms = { "classroom", "elementaryschool", "elementaryhall", "schoolstorage", "schoolgymstorage", "universitystorage", "universityclassroom" },
        color = { r = 0.92, g = 0.76, b = 0.18 },
    },
    grocery = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Grocery",
        rooms = { "grocery", "gigamart", "conveniencestore", "grocerystorage" },
        color = { r = 0.60, g = 0.78, b = 0.24 },
    },
    gas = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Gas",
        rooms = { "fossoil", "gas2go", "gasstore", "gasstorage" },
        color = { r = 0.56, g = 0.26, b = 0.74 },
    },
    tools = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Tools",
        rooms = { "toolstore", "mechanic", "carsupply", "toolstorage", "toolstorestorage" },
        color = { r = 0.60, g = 0.40, b = 0.20 },
    },
    outdoor = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Outdoor",
        rooms = { "outdoorsupply", "camping", "hunting", "sportstore", "sportstorage", "campingstorage", "gymstorage" },
        color = { r = 0.16, g = 0.46, b = 0.24 },
    },
    prison = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Prison",
        rooms = { "prisoncells", "cells", "prisonstorage", "prisonlaundry" },
        color = { r = 0.50, g = 0.52, b = 0.58 },
    },
    storage = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Storage",
        rooms = { "warehouse", "storageunit" },
        color = { r = 0.32, g = 0.48, b = 0.66 },
    },
}

-- 穩定顯示/註冊順序（CATEGORIES 為 hash，pairs 無序）。ModOptions 類別勾選與
-- 統一視窗類別格逐鍵到 CATEGORIES 取 nameKey/color，缺鍵自動略過。
MinidoracatMiniMapPOICategories.ORDER = {
    "military", "police", "gunstore", "medical", "pharmacy",
    "fire", "books", "school", "grocery", "gas",
    "tools", "outdoor", "prison", "storage",
}
