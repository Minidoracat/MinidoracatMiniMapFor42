-- MinidoracatMiniMapPOICategories.lua
-- room name → 20 類 POI 分類 + 每類調色盤，純資料表（主 MOD 內建 POI）。
-- 分類邏輯留在本檔（Rust 渲染端只出 raw geometry）；重新分類＝改本檔，改完重跑
-- scripts/gen_poi_data.py 重新烘焙 MinidoracatMiniMapPOIData.lua。
--
-- color = { r, g, b }（0-1）：20 色可辨識調色盤，同時用於圖標上色與區塊填色/框線。
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
-- POI 分類缺口補洞＋electronics/church 新類別（2026-08-06，依據 .omc/research/
-- 2026-08-05-poi-category-gap-from-reset-tool.md，數字皆 poi_raw.json 9254 棟實算）：
--   medical 補 8 鍵：morgue/dentist/dentiststorage/optometrist/optometriststorage/
--     vet/coroneroffice/hospitalhallway——淨新增 9 棟，另 2 棟含 dentist 的複合商業樓
--     從 grocery 接手（歸屬修正）。medical 48→59、grocery 97→95。
--   police 補 12 鍵：evidenceroom/interrogationroom/policehall/policelibrary/
--     policegarage/detectiveoffice/captainoffice/policeoutfitstorage/policeswat/
--     decontamination/armory/swatlocker。armory 依研究文件原建議放 military，實測
--     唯一淨效果是 (6078,5233) 警局被 military 搶走——警局的軍械室不是軍事基地，
--     故改歸 police（軍事基地的 armory 因同棟必有 armystorage 等鍵仍歸 military，
--     冪等——此歸屬依賴當前圖的共現性，非不變量）。swatlocker 依 SWAT 屬警政
--     語意與 policeswat 同家族（唯一命中 (12944,1365) 本就落 police，零行為差異）。
--   prison 補 5 鍵：prisonerbelongings/prisonlocker/prisonarmory/prisonlibrary/
--     contraband。military 補 1 鍵：firearmtraining。軍警群組全數現圖冪等（防未來
--     缺口）；medical 8 鍵中 optometriststorage/vet/coroneroffice/hospitalhallway
--     亦冪等（vet 唯一命中 (12566,1980) 因同棟 pharmacystorage 被 pharmacy 優先接走）。
--   ⚠ 依實測「否決」的研究文件建議鍵：baggagesearch（唯一淨效果＝Louisville 商場
--     (15325,2842) 變軍事）、killbox（唯一淨效果＝兩棟豬屠宰場 (3720/3766,14646)
--     變監獄——killbox 在本圖是屠宰間不是 SWAT 擊殺區）。gunstore ← hunting 亦不採
--     （hunting 既有於 outdoor，跨類雙掛徒增歸屬爭議）。故軍警補鍵全數冪等、
--     military 71/police 18/prison 8 維持不變，此為刻意結果非漏做。
--   electronics 新類別：electronicsstore（.lotheader 雙 s 拼法，勿「修正」）＋
--     electronicstore（Distributions.lua 頂層單 s 拼法，實掃 1 棟獨立命中
--     (11856,6807) 影帶/電器複合行）＋electronicsstorage。52 棟（其中 3 棟店住
--     混合含臥室 ≈5.8%、1 棟為含電器行的購物中心 (6182,5340)；研究文件的
--     「+47/雜訊 0%」以本 repo poi_raw.json 重算不出來，以實測為準）。
--   church 新類別：church/officechurch/lobbychurch（lobbychurch 實掃有 1 棟獨立
--     附屬棟 (12571,3307)）。31 棟；另 6/37 含 church 房間的建物被較高優先級接走
--     （含 2 棟殯儀館 (12600,3352)/(13138,1510) 因本波 morgue 鍵歸 medical），
--     屬既定優先級語意。兩新類於 CATEGORY_PRIORITY 刻意墊底，不從既有 14 類
--     接手建物。合計 636→728 筆（+9 medical +52 electronics +31 church）。
--
-- 第三梯次：farm/industry/retail/food 四新類（2026-08-06，同一研究文件的判斷題章節；
-- 鍵清單依 poi_raw.json 逐鍵實算＋Distributions.lua/SuburbsDistributions.lua loot
-- 佐證推導，重置工具 room_names.py 家族分節為語意底稿。家族層級記錄如下，
-- 逐鍵數字見當日量測（總命中/淨新增/住宅雜訊三欄全數過目））：
--   farm 15 鍵（研究文件 _FARM_MISC 16 鍵剔 shed）：378 棟、住宅雜訊 3/378=0.8%。
--     shed 剔除依 2026-08-06 review 實測：單鍵 99 棟中 83 棟是單房間後院工具棚
--     （bbox 中位 12 格、無 barn/farmstorage 共現）——主效果是誤標，同 killbox/
--     baggagesearch 判準；且「臥室共現」指標對單房建物盲視（收 shed 時帳面 2.5%
--     實為系統性低估）。woodshed(4 棟) 保留。含 8 個無 loot 表的專屬身分鍵
--     （stable/pigsty 等，沿 bunker「位置存在」前例）。
--   industry 52 鍵（工廠/工坊/工地家族）：163 棟、住宅雜訊 3.1%。刻意剔除
--     workshop（11 淨新增中 8 棟是住家工作間）、machinery/carupholsteryworkshop
--     （無 loot 且零效果）、carpenter（raw 實際拼法是大寫 Carpenter，唯一命中棟
--     已由 tools 接手，死鍵）。construction 是最大鍵（77 淨新增，工地建材有導航
--     價值，佔本類 48%，故 EN 標籤用 Industry / Worksite）。
--   retail 67 鍵（服飾/家具/禮品/郵局/當舖等零售家族）：126 棟、住宅雜訊 31%
--     （主街店住混合為常態，clothesstore 單鍵 16/29 含臥室，沿研究文件判斷收錄）。
--     fishingstorage 改歸 outdoor（釣具屬戶外家族，+10 棟）；gardeningstorage
--     不收（研究文件無 loot 黑名單，7 棟純幾何）；fishing 不收（4 棟中 2 棟住宅）。
--   food 103 鍵（餐廳/廚房/酒吧/食品工廠家族）：325 棟、住宅雜訊 12%。刻意剔除
--     emptykitchen/pantry/coldroom（住宅噪音）與 coldstorage/bottlestorage/
--     cannedstorage/foodcourt/groceryfreezer（無 loot 泛用倉儲或零效果）。
--   優先級尾端 [electronics, church, farm, industry, retail, food, storage] 是
--     實測約束，理由與逐項數字見 gen_poi_data.py CATEGORY_PRIORITY 註解；
--     industry<retail 由 7 棟爭議建築 6:1 定案（工廠附設直售店為主流，唯一反例
--     (13412,1279) 裝修中商店街因 construction 歸 industry，屬已知取捨）。
--   storage 81→71（−10 主身分修正：咖啡店/工廠/郵局街區原掛倉儲圖標）、
--     outdoor 39→49（+10 fishingstorage）、其餘 14 類含 electronics/church 不動。
--   合計 728→1720 筆（+378 farm +163 industry +126 retail +325 food ±10 位移，
--     3 筆 bbox 全等 dup 壓掉）。
--
-- v2 房間級重做（2026-08-06，玩家回報 (10051,12613) 公寓被標倉儲後的根本修）：
--   poi_raw.json 改由 pzmap poi v2 產出——每棟建築帶逐房間幾何
--   （rooms: [{name, level, rects:[[x,y,w,h],…]}]，.lotheader rooms 段原始座標）。
--   烘焙兩個新行為：(1) 條目 bbox 錨定主身分觸發房的 rect 聯集（圖標釘在商場
--   裡的藥局、公寓一樓的店面，不再是整棟外框中心）；(2) 附屬型觸發房門檻——
--   觸發房全屬 ACCESSORY_ROOMS（storage/prison/school 附屬家族，清單與實錘
--   案例見 gen_poi_data.py）時面積佔比須 ≥10%，否則落給下一命中類別。
--   同外框 building 紀錄「先合併再分類」（同棟地下室/地面層在 .lotheader 是
--   獨立紀錄，全圖 10 組——分開分類會任意保留較差錨點、甚至一棟輸出
--   storage+food 雙圖標，codex review 實錘）：合併後一棟物理建築恰做一次
--   gate/priority/anchor。
--   本波同時補 school 三鍵 secondaryclassroom/secondaryhall/schoollab（review
--   抓出：中學根本沒有 classroom 房，v1 靠 schoolstorage 拐杖誤中副車，門檻
--   拆掉拐杖後 3 棟高中曾落到保健室的 medical——補鍵後翻回，含 1 棟 v1 時代
--   就誤判 medical 的 (8321,11595)；secondaryhall/schoollab 現圖冪等）。
--   全圖 23 棟歸屬變更（14 棟退場：7 公寓倉儲、5 場館戶外、監獄外圍場地棟、
--   1 辦公樓；9 棟改判到真實身分：商場→藥局、保齡球館/俱樂部→餐飲、儲物樓
--   →圖書、高中→學校等），真設施零誤殺（真學校有 classroom/secondaryclassroom
--   觸發、真監獄佔比 ≥17%、U-Store It ≥11%、真槍店/藥局等店面型不設門檻）。
--   位移（對 0.12.0 發布基準）：pharmacy 27→28、books 22→24、school 36→32、
--   grocery 95→96、prison 8→6、storage 71→62、outdoor 49→41、food 325→328、
--   medical/retail 等其餘不變。合計 1720→1704 筆（10 筆同外框紀錄合併）。
--   v3 逐房間矩形：條目從聯集框改帶主身分觸發房的逐矩形清單，經「主樓層
--   過濾」（取該類面積最大樓層，平手取最低層——跨樓層 2D 堆疊是區塊疊色
--   與框線層疊的根源，同層房間物理互斥，過濾後重疊對數實測歸零）＋「相鄰
--   合併」（同層貼齊的同類房間併成大矩形，教室一排＝一塊）。最終 1704 筆
--   共 4764 個矩形（51% 單矩形、最大單筆 32——合併前警局 212）。r 按面積
--   大→小排序，圖標/名稱經 iconOnce 旗標只錨定 r[1]（最大房間），防大建築
--   疊數百顆圖標——實測異類圖標近距對數不增反微降（≤5 格 7→6 對）。
--   配套：fill/line/icons 三 pass 皆有世界座標視野預裁（區塊全開在城市尺度
--   曾 8 FPS，預裁＋主樓層＋合併三刀後恢復可用水位）。
--
-- ⚠ CATEGORIES 各 entry 內不要插註解行——scripts/gen_poi_data.py 以 regex 解析
--   nameKey/rooms 相鄰結構，entry 內註解會使該類別解析失敗而整類消失。

MinidoracatMiniMapPOICategories = MinidoracatMiniMapPOICategories or {}

MinidoracatMiniMapPOICategories.CATEGORIES = {
    military = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Military",
        rooms = { "armystorage", "armysurplus", "armytent", "oldarmy", "bunker", "firearmtraining" },
        color = { r = 0.42, g = 0.45, b = 0.20 },
    },
    police = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Police",
        rooms = { "policeoffice", "policestorage", "policegunstorage", "policelocker", "policearchive", "evidenceroom", "interrogationroom", "policehall", "policelibrary", "policegarage", "detectiveoffice", "captainoffice", "policeoutfitstorage", "policeswat", "decontamination", "armory", "swatlocker" },
        color = { r = 0.20, g = 0.42, b = 0.85 },
    },
    gunstore = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Gunstore",
        rooms = { "gunstore", "gunstorestorage", "gunstorage" },
        color = { r = 0.55, g = 0.12, b = 0.14 },
    },
    medical = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Medical",
        rooms = { "hospitalroom", "medical", "medicaloffice", "clinic", "medclinic", "oldmedical", "medicalstorage", "hospitalstorage", "morgue", "dentist", "dentiststorage", "optometrist", "optometriststorage", "vet", "coroneroffice", "hospitalhallway" },
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
        rooms = { "classroom", "elementaryschool", "elementaryhall", "secondaryclassroom", "secondaryhall", "schoollab", "schoolstorage", "schoolgymstorage", "universitystorage", "universityclassroom" },
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
        rooms = { "outdoorsupply", "camping", "hunting", "sportstore", "sportstorage", "campingstorage", "gymstorage", "fishingstorage" },
        color = { r = 0.16, g = 0.46, b = 0.24 },
    },
    prison = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Prison",
        rooms = { "prisoncells", "cells", "prisonstorage", "prisonlaundry", "prisonerbelongings", "prisonlocker", "prisonarmory", "prisonlibrary", "contraband" },
        color = { r = 0.50, g = 0.52, b = 0.58 },
    },
    storage = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Storage",
        rooms = { "warehouse", "storageunit" },
        color = { r = 0.32, g = 0.48, b = 0.66 },
    },
    electronics = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Electronics",
        rooms = { "electronicsstore", "electronicstore", "electronicsstorage" },
        color = { r = 0.20, g = 0.85, b = 0.90 },
    },
    church = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Church",
        rooms = { "church", "officechurch", "lobbychurch" },
        color = { r = 0.90, g = 0.45, b = 0.65 },
    },
    farm = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Farm",
        rooms = { "barn", "cattleauction", "chickencoop", "eggstorage", "farmstorage", "greenhouse",
            "haystorage", "horsebox", "horsewashingstation", "kennels", "pigsty", "potatostorage",
            "producestorage", "stable", "woodshed" },
        color = { r = 0.93, g = 0.87, b = 0.60 },
    },
    industry = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Industry",
        rooms = { "batfactory", "batteryfactory", "batterystorage", "blacksmith", "cabinetfactory",
            "cabinetshipping", "cardfactory", "carpentryworkshop", "construction",
            "derelict_steelfactory", "derelict_steelfactorystorage", "factory", "factorystorage",
            "furnitureworkshop", "glassmakingworkshop", "golffactory", "golfshipping", "guitarfactory",
            "guitarshipping", "handlefactory", "hingefactory", "hingeshipping", "hingestorage",
            "industry", "knifefactory", "knifeshipping", "leatherworkshop", "loggingfactory",
            "loggingwarehouse", "mannequinfactory", "mannequinpainting", "mapfactory", "metalclassroom",
            "metalfabrication", "metalshipping", "metalshop", "paintershop", "plumber",
            "potteryworkshop", "radiofactory", "radioshipping", "railroadrepair", "tablefactory",
            "tableshipping", "tailoringworkshop", "tailorworkshop", "weldingbooth", "weldingstorage",
            "weldingworkshop", "whittlerworkshop", "wirefactory", "woodcraftset" },
        color = { r = 0.68, g = 0.56, b = 0.04 },
    },
    retail = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Retail",
        rooms = { "aesthetic", "aestheticstorage", "antique", "artstore", "barbequestore",
            "baseballgiftstorage", "baseballgiftstore", "baseballstorage", "baseballstore",
            "camerastore", "cdstore", "clothesestorage", "clothesstorage", "clothesstore",
            "clothesstorestorage", "clothingstorage", "clothingstore", "comicstorage", "comicstore",
            "departmentstorage", "departmentstore", "florist", "furnitureshowroom", "furniturestorage",
            "furniturestore", "furniturestorestorage", "gardenstore", "giftstorage", "giftstore",
            "giftstorestorage", "glassesstore", "golfstore", "hairdresser", "housewarestorage",
            "housewarestore", "jewelrystorage", "jewelrystore", "kitchenwares", "knifestore",
            "leatherclothesstore", "lightingstorage", "lightingstore", "masonrystore", "movierental",
            "musicstorage", "musicstore", "pawnshop", "pawnshopoffice", "pawnshopstorage", "petstore",
            "post", "poststorage", "sewingstorage", "sewingstore", "shoestorage", "shoestore",
            "tailorstorage", "tobaccostorage", "tobaccostore", "toystorage", "toystore",
            "toystorestorage", "walletshop", "weddingstoredress", "weddingstoresuit",
            "weddingstorestorage", "windowsstore" },
        color = { r = 0.78, g = 0.16, b = 0.52 },
    },
    food = {
        nameKey = "UI_MinidoracatMiniMap_Cat_Food",
        rooms = { "arenakitchen", "bakery", "bakeryfactorykitchen", "bakeryfactoryshipping",
            "bakeryfactorystorage", "bakerykitchen", "bandkitchen", "bar", "barcountertwiggy",
            "barkitchen", "barstorage", "beergarden", "brewery", "brewerystorage", "burgerdining",
            "burgerkitchen", "burgerstorage", "butcher", "butchery", "cafe", "cafekitchen",
            "cafeteria", "cafeteriakitchen", "candystore", "catfish_dining", "catfish_kitchen",
            "chili_dining", "chilikitchen", "chinesekitchen", "chineserestaurant", "cornerstore",
            "cornerstorestorage", "deepfry_dining", "deepfry_kitchen", "diner", "dinerbackroom",
            "dinercounter", "dinerkitchen", "dining_crepe", "distillerystorage", "distilleryworkshop",
            "dogfoodfactory", "dogfoodshipping", "dogfoodstorage", "donut_dining", "donut_kitchen",
            "fishchipskitchen", "fryshipping", "generalstore", "generalstorestorage", "gigamartkitchen",
            "hotdogstand", "icecream", "icecreamkitchen", "icecreamstand", "italiankitchen",
            "italianrestaurant", "jayschicken_dining", "jayschicken_kitchen", "jerkycoldroom",
            "jerkyfactory", "jerkyshipping", "jerkysmoker", "juicestand", "kitchen_crepe",
            "knoxbutcher", "liquorstore", "mexicandining", "mexicankitchen", "pizzakitchen",
            "pizzawhirled", "pizzawhirledcounter", "porkshipping", "restaurant", "restaurantdining",
            "restaurantdining_fancy", "restaurantkitchen", "restaurantkitchen_fancy",
            "restaurantstorage", "seafooddining", "seafoodkitchen", "slaughterhousepork",
            "sodabottling", "sodashipping", "sodastorage", "sodatruck", "spiffo_dining",
            "spiffoskitchen", "spiffosstorage", "sushidining", "sushikitchen", "tacokitchen",
            "theatrekitchen", "tofufactory", "tofushipping", "tofustorage", "westerndining",
            "westernkitchen", "whiskeybottling", "whiskeyshipping", "whiskystorage", "zippeestorage",
            "zippeestore" },
        color = { r = 0.99, g = 0.60, b = 0.48 },
    },
}

-- 穩定顯示/註冊順序（CATEGORIES 為 hash，pairs 無序）。ModOptions 類別勾選與
-- 統一視窗類別格逐鍵到 CATEGORIES 取 nameKey/color，缺鍵自動略過。
MinidoracatMiniMapPOICategories.ORDER = {
    "military", "police", "gunstore", "medical", "pharmacy",
    "fire", "books", "school", "grocery", "gas",
    "tools", "outdoor", "prison", "storage", "electronics",
    "church", "farm", "industry", "retail", "food",
}
