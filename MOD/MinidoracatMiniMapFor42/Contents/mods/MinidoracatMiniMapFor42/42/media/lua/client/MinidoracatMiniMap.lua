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

-- 跨檔命名空間（單一全域）：主檔拆分為 MinidoracatMiniMap_FloatIcon/_Migrate/_Settings
-- 三個模組檔——Kahlua 編譯器每個函式原型（含每檔主 chunk）locvar 上限 200
-- （LexState.new_localvar 固定陣列，超過＝整檔拒載、MOD 全滅），單檔主 chunk 曾貼頂，
-- 拆檔＝每檔獨立額度。共用成員於檔尾一次匯出（含 ready 閘門）；PZ 依字母序載入
-- 同目錄檔案（'.' 0x2E < '_' 0x5F），本檔必先載、模組檔載入時命名空間已就緒。
local Core = {}
MinidoracatMiniMapCore = Core

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
-- 選配 mapDir＝該條目的地圖目錄名（media/maps/ 下資料夾）：一個 mod 內含多張地圖
-- （如 SecretZ 12 據點）時指定——MP 伺服器 Map= 沒載入該目錄就不掛載也不畫框；
-- 省略＝只看 mapMod（單地圖 mod 不需要）。
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
            and (e.mapDir == nil or type(e.mapDir) == "string")
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

-- Zone 渲染 API（家族第四個 addon＝MinidoracatMiniMapZonesFor42 的資料層專用）：
-- 資料 addon 註冊 provider，本 MOD 每幀呼叫取回「已翻譯、已正規化」的 zone 陣列，
-- 在小地圖與世界地圖填半透明色＋畫框線＋標名稱。zoneApiVersion 供 addon 掛載前守衛
-- 版本（契約 C1）——舊主 MOD 無此欄位／無 registerZoneProvider，addon 應安靜降級。
-- provider 契約（C2）：providerFn 每幀被呼叫（世界＋小地圖），必須回傳「快取 table」、
-- 勿每幀重建/過濾/合併；本 MOD 對回傳只讀不改。zone schema（provider 產、繪製端讀）：
--   { id=string, name=string|nil(已翻譯顯示名；nil＝不畫名稱),
--     rects={ { x1=, y1=, x2=, y2= }, ... }(世界 square 座標；硬性要求 x1<x2、y1<y2——
--       三個 pass 的視野預裁都假設此序，反向 rect 會被一致地過嚴裁掉而整個消失),
--     fill={ r=, g=, b= }(0-1), fillAlpha=number(0＝不填),
--     border={ r=, g=, b= }(0-1), borderAlpha=number(0 或缺 border＝不畫框；
--       ⚠ 不影響 name——兩者自 2026-08-13 解耦，純色塊＋名稱是合法組合),
--     haloAlpha=number|nil(選配；>0＝fill pass 於細節檔在每 rect 填色下先畫
--       外擴 2px 的黑色底襯 quad——無框線區塊的暗色描邊，每 rect 僅 1 次
--       drawPolygon（stencil 裁切、零 Lua 裁線），遠低於 4 條框線的成本；
--       中距/拉遠檔不畫。POI 區塊模式用；無此欄位行為不變),
--     icon={ tex=<Texture>, r=, g=, b= }|nil(選配；每 rect 中心畫染色圖標),
--     iconOnce=true|nil(選配；true 時圖標只畫在 rects[1]——provider 應把主要
--       矩形排在首位；名稱本就恆只錨定 rects[1]、與此旗標無關。未設維持
--       每 rect 一圖標，既有 addon 行為不變),
--     iconRect={ x1=, y1=, x2=, y2= }|nil(選配；覆寫第一顆圖標的錨定矩形，
--       不影響 fill/line/名稱。POI 整棟外框模式用：框畫整棟、圖標仍釘在
--       最大房間。四欄不齊者忽略、回退 rects[1]),
--     distRects={ {x1=,y1=,x2=,y2=},.. }|nil(選配；覆寫 POI 顯示距離閘的量測
--       對象，預設量 rects。整棟外框模式用：畫整棟框但距離仍由分類房間決定，
--       使該開關純屬外觀、不改變可見距離。僅 internal provider 受距離閘),
--   zones「表本身」可帶選配聚合旗標 hasFill/hasLine/hasIcon（ZR-1）：false＝
--     provider 聲明該 pass 無任何可畫內容，renderer 整段跳過迴圈（內建 POI 預設
--     純圖標模式靠此免去 fill/lines 每幀空掃全部 zone）；nil＝未聲明，照舊逐
--     zone 判斷——外部 addon 不設即行為不變。旗標須與內容同步重建（錯設漏畫是
--     provider 的 bug）。
--     lodRect={ x1=, y1=, x2=, y2= }|nil(選配；有給＝參與縮放 LOD——
--       worldScale < ZONE_LOD_HIDE 時 fill 整區不畫、< ZONE_LOD_DETAIL 時
--       fill 只畫此聯集框（純填色，框線與名稱僅細節檔）、圖標於 < DETAIL 時
--       做同格去重疊（同一「圖標尺寸」螢幕格只畫第一顆，細節檔全畫）。
--       未設＝一律畫全部 rects、圖標不去重疊，既有 addon 行為不變),
--     category=string|nil }
-- 選配第三參 optionLabelKey：有給時本 MOD 於統一視窗動態追加一顆 per-provider 母開關
-- （如「顯示伺服器區域」），關＝渲染時整個跳過該 provider。
-- 選配第四參 internal：true＝本體內部 provider（如內建 POI），不受 ZoneLayer 總閘連坐、
-- 由自家開關（PoiIcons/PoiBlocks/類別）控制；外部 addon 一律省略（受 ZoneLayer 總閘）。
-- ⚠ 傳 internal 者同時受 POI 顯示距離閘（沙盒 PoiDisplayDistance/AllInfoDistance＋
-- 玩家自訂距離）連坐——距離啟用時 zone 會依玩家距離被靜默裁掉，外部 addon 勿傳。
local registeredZoneProviders = {} -- { { owner=, fn=, optionLabelKey=, optionKey=, internal= }, ... }
-- ZoneLayer 總開關的 UI 出現條件＝「有『外部』provider」：內建 POI（internal=true）
-- 繞過 ZoneLayer 閘門（見 drawZoneFill/Lines/Icons 的 gating），若把 internal 也計入，
-- 純本體安裝會出現一顆對任何東西都無作用的死開關（codex review 抓出）。
local function hasExternalZoneProvider()
    for i = 1, #registeredZoneProviders do
        if not registeredZoneProviders[i].internal then return true end
    end
    return false
end
MinidoracatMiniMapAPI.zoneApiVersion = 1
function MinidoracatMiniMapAPI.registerZoneProvider(ownerModId, providerFn, optionLabelKey, internal)
    if type(ownerModId) ~= "string" or ownerModId == "" or type(providerFn) ~= "function" then
        print("[MinidoracatMiniMap] registerZoneProvider bad arguments (need ownerModId string, providerFn function)")
        return
    end
    local entry = { owner = ownerModId, fn = providerFn, internal = internal and true or nil }
    if type(optionLabelKey) == "string" and optionLabelKey ~= "" then
        entry.optionLabelKey = optionLabelKey
        -- per-provider ModOptions key（ini 用；非字母數字換底線求穩定合法）
        entry.optionKey = "ZoneProv_" .. ownerModId:gsub("[^%w]", "_")
    end
    table.insert(registeredZoneProviders, entry)
end

-- Zone 動作 API（通用小 API，供 zone-layer addon 在統一視窗「圖層顯示」區追加一列動作）：
-- 主 MOD 於伺服器區域 tick 之後渲染 [combo]+[按鈕]（options 有給才有 combo）；按鈕點擊呼叫
-- onTrigger(選中的 value)。無註冊＝零列（dormant）。spec 契約：
--   { labelKey=string(按鈕文字鍵), tooltipKey=string|nil,
--     options={ { value=any, labelKey=string }, ... }|nil(nil＝純按鈕),
--     onTrigger=function(value)(value＝選中 option 的 value，無 options 時為 nil) }
-- test:zone-action:start
local registeredZoneActions = {} -- { { owner=, labelKey=, tooltipKey=, options=, onTrigger= }, ... }
function MinidoracatMiniMapAPI.registerZoneAction(ownerModId, spec)
    if type(ownerModId) ~= "string" or ownerModId == "" or type(spec) ~= "table"
        or type(spec.labelKey) ~= "string" or spec.labelKey == ""
        or type(spec.onTrigger) ~= "function" then
        print("[MinidoracatMiniMap] registerZoneAction bad arguments (need ownerModId, spec.labelKey, spec.onTrigger)")
        return
    end
    local options = nil
    if type(spec.options) == "table" then
        options = {}
        for i = 1, #spec.options do
            local o = spec.options[i]
            if type(o) == "table" and type(o.labelKey) == "string" and o.labelKey ~= "" then
                options[#options + 1] = { value = o.value, labelKey = o.labelKey }
            end
        end
        if #options == 0 then options = nil end -- 全部無效＝視同無 options（純按鈕）
    end
    table.insert(registeredZoneActions, {
        owner = ownerModId,
        labelKey = spec.labelKey,
        tooltipKey = (type(spec.tooltipKey) == "string" and spec.tooltipKey ~= "") and spec.tooltipKey or nil,
        options = options,
        onTrigger = spec.onTrigger,
    })
end
-- test:zone-action:end

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
-- （浮動開關圖標已拆至 MinidoracatMiniMap_FloatIcon.lua；modOptions:apply 改經
--  Core.updateFloatIconVisibility 呼叫時查表＋nil 防呆——模組檔載入序在本檔之後）

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

-- 一 mod 多地圖（SecretZ 類）的逐圖閘門：MP 伺服器可在 Map= 只挑部分地圖目錄
-- 載入，mod ID 閘門看不出這層差異（回報實例：未載入的 SecretZ 據點仍被畫出）。
-- getWorld():getMap()（Java Core.gameMap）＝實際載入地圖目錄的分號串列——單機為
-- MapGroups 串起的全部啟用 MOD 目錄、MP 客戶端為伺服器 Map= 清單（世界 init 時
-- IsoMetaGrid.getLotDirectories 回填；42.19 反編譯查證），兩種模式皆可信。
-- 約束：僅供世界 init 之後呼叫（連線早期 Core.gameMap 短暫只有首項）——現有
-- 呼叫點（applyMiniMapPyramids 各觸發源）皆滿足；新增更早呼叫點前先想這條。
-- test:mapdir-gate:start
local function getLoadedMapDirs()
    local okCall, mapStr = pcall(function()
        local world = getWorld()
        return world and world:getMap() or nil
    end)
    if not okCall or type(mapStr) ~= "string" or mapStr == "" or mapStr == "DEFAULT" then
        return nil -- 拿不到＝fail-open 退回純 mod ID 閘門（行為同無 mapDir 版本）
    end
    local dirs = {}
    for dir in string.gmatch(mapStr, "[^;]+") do
        dir = dir:match("^%s*(.-)%s*$")
        if dir ~= "" then dirs[dir] = true end
    end
    -- PZ Kahlua 無 next（BaseLib.java 僅註冊 18 個全域、TableLib 只有 pairs/ipairs），
    -- 空表偵測用 pairs 探測——0.10.0 曾用 next 導致實機掛載鏈全炸（離線測試跑標準 Lua 沒抓到）
    for _ in pairs(dirs) do return dirs end
    return nil -- 拆完是空集＝同「拿不到」，fail-open
end

-- 條目沒指定 mapDir、或載入清單拿不到＝通過；指定了就要求該目錄真的載入。
-- 空字串視同未指定（codex review：validator 放行 ""，但 "" 永遠匹配不到——
-- 單點中和、不整條目拒收，壞欄位只降級回 mod ID 閘門）
local function passesMapDir(entry, loadedDirs)
    return entry.mapDir == nil or entry.mapDir == ""
        or loadedDirs == nil or loadedDirs[entry.mapDir] == true
end
-- test:mapdir-gate:end

-- 重建框線資料（世界地圖/小地圖各 init 一次呼叫，冪等）：來源＝已註冊地圖包；
-- 有 bounds 且對應地圖 MOD 啟用者才畫框。框線是 Lua 自繪定位輔助——不依賴 zip
-- 是否渲染、不受「顯示 MOD 地圖區塊」與「圖片化地圖」開關影響，故自
-- collectPyramids 拆出、置於圖片化閘門之前（codex review：閘門原在前會讓
-- 關閉圖片化啟動時框線資料永遠空白）
-- test:rebuild-overlays:start
local function rebuildMapOverlays()
    local mods = getActivatedMods()
    local active = {}
    for i = 1, mods:size() do active[mods:get(i - 1)] = true end
    local loadedDirs = getLoadedMapDirs()
    for i = #mapOverlays, 1, -1 do mapOverlays[i] = nil end
    for _, pack in ipairs(registeredPacks) do
        for _, entry in ipairs(pack.entries) do
            if entry.bounds and entry.mapMod and active[entry.mapMod]
                and passesMapDir(entry, loadedDirs) then
                table.insert(mapOverlays, entry)
            end
        end
    end
end
-- test:rebuild-overlays:end

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
    local loadedDirs = getLoadedMapDirs()

    -- (1) 本 MOD manifest：基底 + 已啟用地圖 MOD 的圖檔。缺檔一律有 log——
    -- zip 是 gitignored 產物，「漏渲染／漏打包」是最可能的事故，不能靜默
    local own = getModInfoByID(OWN_MOD_ID)
    if own then
        for _, entry in ipairs(MAPS) do
            if (not entry.mapMod or active[entry.mapMod]) and passesMapDir(entry, loadedDirs) then
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
                    if (not entry.mapMod or active[entry.mapMod]) and passesMapDir(entry, loadedDirs) then
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

-- 已掛載樣式層 id 集（世界地圖/小地圖同名共用）：關閉圖片化時逐 id 卸載。
-- 刻意不走 Reapply Style（initDefaultStyleV3 內含 styleAPI:clear()，會把「其他
-- MOD」掛的樣式圖層一併洗掉、對方未必有補掛 hook——codex review 抓出）
local mountedLayerIds = {}
local appliedWorldImagery -- 世界地圖側已套用狀態快照（nil＝尚未掛載過；apply 比對用）
local function removeMiniMapPyramidLayers(mapUI)
    local styleAPI = mapUI.mapAPI:getStyleAPI()
    for layerId in pairs(mountedLayerIds) do
        if styleAPI:indexOfLayer(layerId) ~= -1 then
            styleAPI:removeLayerById(layerId) -- 原版用例：initDefaultStyleV3 移除 "forest"
        end
    end
end

-- 純決策（離線測試 scripts/test_layer_tail.lua）：本 MOD 各圖層現值 index 陣列
-- （依註冊順序；-1＝缺層）是否「以原順序連續佔據樣式尾端」；否＝需拆掉重掛。
-- 引擎按 index 由下往上畫（WorldMapRenderer.renderCellFeatures 0→N、後建在上），
-- 圖層存在但被壓在向量層之下時，water/forest 多邊形會畫在影像上（如 AnruisiTown
-- 城南向量湖泊蓋過倉庫區影像＝玩家所見「一大片藍色遮蓋」，2026-08-03 地圖包
-- 許願串 #4——該狀態的成因尚待自癒證據行從 console.txt 佐證：原版重建路徑
-- 全是 initDefaultStyleV1 的 styleAPI:clear() 起手、全有全無，單靠原版走不到
-- 「壓下」，只有第三方加層或未定位路徑會）。穩態基準＝V3+overlayPaper 重建後
-- 本 MOD 補掛在最後，故「連續尾端」判定與正常流程一致、穩態零動作。
-- test:layer-tail:start
local function layersNeedRebuild(indices, layerCount)
    for i = 1, #indices do
        -- -1 哨兵不可進算式：layerCount == #indices - i 時期望值恰為 -1，
        -- 缺層會被誤判就位（實務上 apply 恆在原版鋪 ~10 層後，防禦性守衛）
        if indices[i] == -1 then
            return true
        end
        if indices[i] ~= layerCount - #indices + i - 1 then
            return true
        end
    end
    return false
end
-- test:layer-tail:end

-- 樣式層掛載/自癒執行段（離線整合測試 scripts/test_layer_tail.lua 以 fake
-- styleAPI 打樁）：去重→stale 清掃→尾端檢查→必要時拆掉按序重掛。
-- 本 MOD 圖層恆佔樣式最上層是產品契約：層是全縮放不透明底圖，語意上必須蓋過
-- 向量層；代價＝第三方 MOD 若晚於本 MOD append style layer，會在本 MOD 覆蓋
-- 範圍內被壓下（兩個都做尾端守恆的 MOD 會互搶，非每幀、拆掛廉價，可接受）。
-- 刻意用拆掛而非 moveLayer（原版用例 ISMapDefinitions.lua:347）：pyramid 層只持
-- fileName+fill、圖資在 WorldMap images 側（WorldMapPyramidStyleLayer.java:10-11）
-- 不隨層拆建卸載，重建趨近零成本；moveLayer 得逐層搬＋自算位移 index。
-- test:layer-mount:start
local function mountPyramidLayers(styleAPI, entries)
    -- 每個「檔名」一層（引擎一層只綁一個檔名）——先以 layerId 去重：registry 有
    -- 同 zip 的 alias 條目（Chinatown 互斥變體）、legacy 約定名多 addon 同檔名。
    -- 重複 id 不會拋錯（WorldMapStyle.java:40-44 的 addLayer 無唯一性檢查；
    -- V1/V2 簽名的 throws IllegalArgumentException 是裝飾性宣告、整包無 throw
    -- 點）——後果更陰險：同 id 幽靈層讓 indexOfLayer/removeLayerById 只認第一
    -- 筆，尾端檢查永不成立＝每次呼叫全拆全掛＋log 刷屏。去重是「無條件重掛」
    -- 設計的必要前提（舊碼靠 indexOfLayer 跳過取得隱式去重，本函式必須顯式化）
    local uniqEntries, layerIds, seen = {}, {}, {}
    for _, e in ipairs(entries) do
        local layerId = "minidoracat_" .. (e.zip:gsub("%.pyramid%.zip$", ""))
        if not seen[layerId] then
            seen[layerId] = true
            uniqEntries[#uniqEntries + 1] = e
            layerIds[#layerIds + 1] = layerId
            mountedLayerIds[layerId] = true -- 記錄本 MOD 圖層 id（卸載用；重複記錄無妨）
        end
    end

    -- stale 清掃：上次掛過、本次不在集內的本 MOD 層（MapPackLayers 關閉、MP
    -- mapDir 閘門收緊）從「這個」style 移除——修掉世界地圖不重建就殘留舊圖層
    -- 的既有缺口。只動 styleAPI、不動共用 registry：mountedLayerIds 由世界地圖
    -- 與小地圖兩個 style 共用，刪 key 會讓另一側 removeMiniMapPyramidLayers 漏卸
    for id in pairs(mountedLayerIds) do
        if not seen[id] and styleAPI:indexOfLayer(id) ~= -1 then
            styleAPI:removeLayerById(id)
        end
    end

    -- 尾端守恆檢查（快照必須在清掃後：清掃會位移 index）。
    -- log 只在真正動層時輸出——本函式被開圖/樣式重建冪等重跑，無條件 log 會刷屏
    local indices, existed = {}, 0
    for i = 1, #layerIds do
        indices[i] = styleAPI:indexOfLayer(layerIds[i])
        if indices[i] ~= -1 then existed = existed + 1 end
    end
    if not layersNeedRebuild(indices, styleAPI:getLayerCount()) then return end

    if existed > 0 then
        -- 自癒證據行「先印再動手」（中途失敗仍留診斷）＋指認當前最上層（壓層
        -- 兇手或亂序訊號）：玩家回報「藍色遮蓋」類問題時，console.txt 有此行
        -- ＝命中圖層順序窗口，最上層 id 直接指出來源
        local top = styleAPI:getLayerByIndex(styleAPI:getLayerCount() - 1)
        log("圖層自癒：本 MOD 圖層未連續佔據樣式尾端（現存 " .. existed .. "／應有 "
            .. #layerIds .. "；當前最上層 id=" .. tostring(top and top:getID()) .. "），全數重掛")
    end
    for i = 1, #layerIds do
        if indices[i] ~= -1 then
            styleAPI:removeLayerById(layerIds[i]) -- 原版用例：initDefaultStyleV3 移除 "forest"
        end
    end
    local okBuild, buildErr = pcall(function()
        for i, e in ipairs(uniqEntries) do
            local layer = styleAPI:newPyramidLayer(layerIds[i])
            layer:setPyramidFileName(e.zip)
            layer:addFill(0.0, 255.0, 255.0, 255.0, 255.0)
            if indices[i] == -1 then
                log("已掛載 pyramid: " .. e.path)
            end
        end
    end)
    if not okBuild then
        -- 建層中途失敗：newPyramidLayer 先 append 才設 filename（WorldMapStyleV2
        -- .java:21-25），殘層 id 齊全會讓下次尾端檢查誤判穩態（codex review 抓出）
        -- ——best-effort 全拆保證下次看到缺層必重試，再 rethrow 給呼叫點 pcall
        -- 記 log。最壞狀態＝本次全層消失、下一個掛載觸發點自癒
        for i = 1, #layerIds do
            if styleAPI:indexOfLayer(layerIds[i]) ~= -1 then
                styleAPI:removeLayerById(layerIds[i])
            end
        end
        error(buildErr, 0)
    end
    local added = #layerIds - existed
    if added > 0 then
        log("圖層就緒（新增 " .. added .. "／共 " .. #layerIds .. " 個 pyramid 圖層）")
    end
end
-- test:layer-mount:end

local function applyMiniMapPyramids(mapUI)
    -- 框線資料重建先於圖片化閘門：框線是 Lua 自繪、與圖片化無關（codex review）
    rebuildMapOverlays()
    -- 圖片化地圖總開關（預設開）：本函式是所有掛載路徑（世界地圖 init/樣式重建
    -- 補掛/開圖保險、小地圖 InitPlayer）的唯一入口——單點閘門。關閉時本函式
    -- 不掛載；世界地圖側的即時卸載由 modOptions:apply 呼叫 removeMiniMapPyramidLayers、
    -- 小地圖側由 Recreate 重建
    local imageryOn = getBoolOption("MapImagery", true) == true
    if ISWorldMap_instance and mapUI == ISWorldMap_instance then
        appliedWorldImagery = imageryOn -- 世界地圖側基準（instance 於 init 前已賦值，見下方 wrap 註解）
    end
    if not imageryOn then return end
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

    -- 樣式層：疊在原版樣式之上，不清空原版（刻意不學 showTerrainImage 的
    -- styleAPI:clear()）。掛載/自癒細節見 mountPyramidLayers
    mountPyramidLayers(styleAPI, entries)

    mapAPI:setBoolean("ImagePyramid", true)
end

-- 純決策（離線測試矩陣覆蓋，見 scripts/test_key_migration.lua）：比對快照與現值
-- → 動作計畫。snap.worldImagery＝世界地圖側已套用狀態（nil＝尚未掛載過，不動）；
-- snap.hasMiniMap＝有小地圖實例才處理小地圖側（無小地圖仍要能切世界地圖——
-- AllowMiniMap 關閉情境，codex review 抓出）
-- test:apply-plan:start
local function computeApplyPlan(snap, cur)
    local plan = { reapplyWorldMap = false, clearCustomSize = false, recreate = false, live = false }
    if snap.worldImagery ~= nil and snap.worldImagery ~= cur.imagery then
        plan.reapplyWorldMap = true
    end
    if snap.hasMiniMap then
        local sizeChanged = snap.sizeIndex ~= cur.sizeIndex
        -- 尺寸下拉改動一律先清自訂尺寸——與其他開關同時改動也不可漏清
        -- （舊 elseif 鏈在 imagery+尺寸同改時漏清，codex review 抓出）
        plan.clearCustomSize = sizeChanged and cur.customSize ~= ""
        if (snap.imagery == true) ~= cur.imagery
            or (snap.packLayers == true) ~= cur.packLayers
            or sizeChanged
            or (snap.customSize or "") ~= cur.customSize then
            plan.recreate = true
        else
            plan.live = true
        end
    end
    return plan
end
-- test:apply-plan:end

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

-- 距離沙盒值 0 或缺值＝不限制；僅正數啟用距離閘門。AllInfoDistance＝全域距離
-- 上限（最優先）：與個別距離取較小的正值——個別值只能更嚴、不能放寬全域上限；
-- 只設全域時五類距離項目（殭屍/動物/載具/安全屋/POI）一體生效
-- test:sandbox-distance:start
local function sandboxDist(name)
    local v = sandboxGate(name, 0)
    if type(v) ~= "number" or v <= 0 then v = nil end
    local g = sandboxGate("AllInfoDistance", 0)
    if type(g) == "number" and g > 0 and (not v or g < v) then return g end
    return v
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

-- slider 值（number）；無 PZAPI/選項回預設。夾 min/max：PZAPI load 對 slider
-- 接受任何 number（ModOptions.lua:310-311 不驗證值域），手改 ini 超界要防
local function getSliderValue(id, default, min, max)
    if not modOptions then return default end
    local opt = modOptions:getOption(id)
    local v = opt and opt:getValue()
    if type(v) ~= "number" then return default end
    if min and v < min then return min end
    if max and v > max then return max end
    return v
end

-- 顯示距離合成（取樣/繪製端一律經此取距離）：伺服器個別值（sandboxDist 內已
-- 併全域上限 AllInfoDistance）與玩家自訂值（Client<沙盒選項名>，ESC 頁與統一
-- 視窗「顯示距離」區同一滑條）取較小正值——玩家只能收緊、不能放寬伺服器閘；
-- 0/缺值＝該層不限制
-- test:display-distance:start
local CLIENT_DIST_MAX = 2000 -- 客戶端滑條值域上限（ESC 頁/統一視窗/夾限同值）
local function displayDist(name)
    local server = sandboxDist(name)
    local mine = getSliderValue("Client" .. name, 0, 0, CLIENT_DIST_MAX)
    if mine > 0 and (not server or mine < server) then return mine end
    return server
end
-- test:display-distance:end

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
    -- 穿透模式：外框強制取最淡檔（「看得到摸不到＝變淡」單一心智模型），
    -- 退出時本函式重跑即還原玩家原檔位（_minidoracatBgA 快照）
    if getBoolOption("GhostMode", false) then f = math.min(f, CHROME_FACTORS[3]) end
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
        if getBoolOption("GhostMode", false) then f = math.min(f, CHROME_FACTORS[3]) end
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
-- 按鈕列擴充前置宣告（InitPlayer 要用；本體見按鈕列一節）。統一設定視窗已拆至
-- MinidoracatMiniMap_Settings.lua，開窗入口改經 Core.toggleSettingsWindow 呼叫時查表
local installMinidoracatButtons

-- 尺寸上限（getPlayerScreenWidth/Height 用例 ISMiniMap.lua:701-702）
local function resizeMax(playerNum)
    return math.floor(math.min(getPlayerScreenWidth(playerNum), getPlayerScreenHeight(playerNum)) * RESIZE_MAX_RATIO)
end

-- 7 顆按鈕（M - + C XY ⚙ X）的最小可容寬度抬高 RESIZE_MIN：必須在 InitPlayer 讀
-- CustomSize 夾限「之前」呼叫——installMinidoracatButtons 的同款回寫發生在視窗建立
-- 之後，救不到舊存小尺寸（如 180x180）的本 session 首次建立（X 鈕會溢出右緣）。
-- 字級在 InitPlayer 時已就緒：鈕寬同原版 BUTTON_HGT 公式 getFontHeight(Small)+6
local function raiseResizeMinForButtons()
    local bw = getTextManager():getFontHeight(UIFont.Small) + 6
    local minW = 7 * bw + 6 * 2 + 2 * 2 + 4 -- 7 鈕＋6×2px 間距＋外框 2×2＋4
    if minW > RESIZE_MIN then RESIZE_MIN = minW end
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
    -- 圖片化地圖總開關（預設開）：關閉＝不掛任何 pyramid 圖層，小地圖/世界地圖
    -- 回到原版向量樣式；圖標/資源點等其他功能不受影響。MOD 地圖無渲染圖者本就
    -- 顯示原版樣式（多數地圖 MOD 自帶向量 worldmap 資料），關閉後同理
    modOptions:addTickBox("MapImagery", "UI_MinidoracatMiniMap_MapImagery", true,
        "UI_MinidoracatMiniMap_MapImagery_tooltip")
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
    -- 玩家座標列（預設開）：小地圖底部置中顯示 x, y, z；繪製端每幀讀值即時生效。
    -- 複製功能（XY 鈕/右鍵選單）不受此開關影響
    modOptions:addTickBox("ShowPlayerCoords", "UI_MinidoracatMiniMap_ShowPlayerCoords", true,
        "UI_MinidoracatMiniMap_ShowPlayerCoords_tooltip")
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
    -- 大小/透明度＝滑條（0.9.0，原三檔 combobox）：舊存值由 migrateSliderOptions
    -- 一次性換算（PZAPI addSlider＝ModOptions.lua:206；ESC 頁自帶數值標）
    modOptions:addSlider("ZombieDotSize", "UI_MinidoracatMiniMap_ZombieDotSize", 1, 16, 1, 3)
    modOptions:addSlider("ZombieDotAlpha", "UI_MinidoracatMiniMap_ZombieDotAlphaOpt", 10, 100, 5, 100)
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
    -- 大小/透明度滑條（0.9.0 起動物與載具各自獨立；舊共用 combobox 值一次性換算）
    modOptions:addSlider("AnimalIconSize", "UI_MinidoracatMiniMap_AnimalIconSize", 8, 48, 1, 16)
    modOptions:addSlider("AnimalIconAlpha", "UI_MinidoracatMiniMap_AnimalIconAlphaOpt", 10, 100, 5, 100)
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
    -- 載具大小/透明度滑條（0.9.0 前與動物共用 AnimalIconSize；遷移時以舊值播種）
    modOptions:addSlider("VehicleIconSize", "UI_MinidoracatMiniMap_VehicleIconSize", 8, 48, 1, 16)
    modOptions:addSlider("VehicleIconAlpha", "UI_MinidoracatMiniMap_VehicleIconAlphaOpt", 10, 100, 5, 100)
    -- 世界地圖（M）獨立圖標開關（預設關）：風格/顏色/物種與類別篩選共用小地圖設定
    modOptions:addTickBox("WMZombieDots", "UI_MinidoracatMiniMap_WMZombieDots", false,
        "UI_MinidoracatMiniMap_WM_tooltip")
    modOptions:addTickBox("WMAnimalWild", "UI_MinidoracatMiniMap_WMAnimalWild", false,
        "UI_MinidoracatMiniMap_WM_tooltip")
    modOptions:addTickBox("WMAnimalLivestock", "UI_MinidoracatMiniMap_WMAnimalLivestock", false,
        "UI_MinidoracatMiniMap_WM_tooltip")
    modOptions:addTickBox("WMVehicleDots", "UI_MinidoracatMiniMap_WMVehicleDots", false,
        "UI_MinidoracatMiniMap_WM_tooltip")
    -- 內建 POI（原版地圖資源點，20 類）：圖標為主（預設開）、區塊選配（預設關）。
    -- 繪製與 provider 都在 MinidoracatMiniMapPOI.lua（讀本命名空間的 PoiIcons/PoiBlocks/Cat_*）。
    -- 獨立群組（分隔線＋標題，同下方「顯示距離」慣例）：五顆開關＋兩條滑條＋20 類
    -- 勾選共 27 列，混在扁平清單裡玩家找不到邊界。收尾分隔線由「顯示距離」群組的
    -- addSeparator 兼任（addTitle 只畫標題、不畫群組結束）
    modOptions:addSeparator()
    modOptions:addTitle("UI_MinidoracatMiniMap_SecPoiEsc")
    modOptions:addTickBox("PoiIcons", "UI_MinidoracatMiniMap_PoiIcons", true,
        "UI_MinidoracatMiniMap_PoiIcons_tooltip")
    modOptions:addTickBox("PoiBlocks", "UI_MinidoracatMiniMap_PoiBlocks", false,
        "UI_MinidoracatMiniMap_PoiBlocks_tooltip")
    -- 區塊形狀（預設關＝逐房間；開＝整棟一框）。只作用於區塊模式的填色/框線/名稱，
    -- 圖標錨點不變（POI provider 於整棟模式帶 iconRect 釘住最大房間）
    modOptions:addTickBox("PoiWholeBuilding", "UI_MinidoracatMiniMap_PoiWholeBuilding", false,
        "UI_MinidoracatMiniMap_PoiWholeBuilding_tooltip")
    -- 圖標樣式（預設關＝單色類別色剪影；開＝彩色全彩圖標）。POI provider 依此選材質集。
    modOptions:addTickBox("PoiColorIcons", "UI_MinidoracatMiniMap_PoiColorIcons", false,
        "UI_MinidoracatMiniMap_PoiColorIcons_tooltip")
    -- 大小/透明度滑條（0.9.0 新增；原固定 18px/不透明）——作用於所有 zone 圖標
    -- （POI 為主；Zones addon 帶圖標的區域一併受控）
    modOptions:addSlider("PoiIconSize", "UI_MinidoracatMiniMap_PoiIconSize", 8, 48, 1, 18)
    modOptions:addSlider("PoiIconAlpha", "UI_MinidoracatMiniMap_PoiIconAlphaOpt", 10, 100, 5, 100)
    -- 20 類別勾選（預設全開）：ORDER 定順序，逐鍵到 CATEGORIES 取 nameKey，缺鍵略過。
    local poiCats = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.CATEGORIES
    local poiOrder = MinidoracatMiniMapPOICategories and MinidoracatMiniMapPOICategories.ORDER
    if type(poiCats) == "table" and type(poiOrder) == "table" then
        for i = 1, #poiOrder do
            local key = poiOrder[i]
            local def = poiCats[key]
            if def then modOptions:addTickBox("Cat_" .. key, def.nameKey, true) end
        end
    end
    -- 玩家自訂顯示距離（格；0＝不限制）：與伺服器沙盒距離經 displayDist 取較小者
    -- 生效（只能收緊、不能放寬）。獨立群組放 POI 類別勾選之後（分隔線＋標題走
    -- addTitle，渲染時才 getText，無翻譯時機問題；addDescription 是「註冊時」
    -- getText，本檔載入期翻譯未必就緒，不用）。「0＝不限」提示掛在群組標題而非
    -- 逐列標籤——ESC 的 slider 分支不渲染 tooltip（MainOptions.lua:3024-3031 從未
    -- setTooltip），而逐列加後綴會撐寬統一視窗共用的標籤欄、擠掉滑條軌道。
    -- step=1：沙盒上限是任意整數（如 15），step>1 會讓存值被 ISSliderPanel 先
    -- 進位再夾限，UI/存值/實效三方漂移（codex review 抓出）。統一視窗「顯示
    -- 距離」區有同步滑條；ESC 頁維持全值域，超出部分由合成層夾住。
    modOptions:addSeparator()
    modOptions:addTitle("UI_MinidoracatMiniMap_SecDistanceEsc")
    modOptions:addSlider("ClientZombieDotDistance", "UI_MinidoracatMiniMap_DistZombie", 0, CLIENT_DIST_MAX, 1, 0)
    modOptions:addSlider("ClientAnimalIconDistance", "UI_MinidoracatMiniMap_DistAnimal", 0, CLIENT_DIST_MAX, 1, 0)
    modOptions:addSlider("ClientVehicleIconDistance", "UI_MinidoracatMiniMap_DistVehicle", 0, CLIENT_DIST_MAX, 1, 0)
    modOptions:addSlider("ClientSafehouseDisplayDistance", "UI_MinidoracatMiniMap_DistSafehouse", 0, CLIENT_DIST_MAX, 1, 0)
    modOptions:addSlider("ClientPoiDisplayDistance", "UI_MinidoracatMiniMap_DistPoi", 0, CLIENT_DIST_MAX, 1, 0)
    -- 收尾分隔線：addTitle 只畫標題、不畫群組結束，少了這行後面的外觀選項
    -- （不透明度/鎖定位置/穿透模式…）在視覺上會被歸進「顯示距離」標題底下
    modOptions:addSeparator()
    -- 外框底色不透明度：只影響外框/按鈕列的黑底與其上的視覺重量。
    -- 地圖本體無「整體 element alpha」，但 style layer fill alpha＋背景 quad 可調
    -- ——該機制已由 _Ghost.lua 的 dimMapBody 完整實作並實機驗證（穿透模式限定）；
    -- 此處若要做「非穿透常駐半透明檔位」可複用同一套，目前未出貨
    local opacityCombo = modOptions:addComboBox("Opacity", "UI_MinidoracatMiniMap_Opacity")
    opacityCombo:addItem("UI_MinidoracatMiniMap_Opacity_Full", true) -- 預設原版
    opacityCombo:addItem("UI_MinidoracatMiniMap_Opacity_Half", false)
    opacityCombo:addItem("UI_MinidoracatMiniMap_Opacity_Faint", false)
    -- 鎖定位置：擋標題列拖曳與邊緣縮放（hitResizeEdge 與 titleBar wrap 各自讀值）
    modOptions:addTickBox("LockPosition", "UI_MinidoracatMiniMap_LockPosition", false,
        "UI_MinidoracatMiniMap_LockPosition_tooltip")
    -- 穿透模式（預設關）：點擊/滾輪/右鍵穿透到遊戲世界＋外框強制變淡＋琥珀邊框。
    -- 事件 gate 與套用本體在 MinidoracatMiniMap_Ghost.lua；熱鍵 ' 與 FloatIcon
    -- 右鍵亦可切換（三處設定面＋熱鍵讀寫同一選項值）
    modOptions:addTickBox("GhostMode", "UI_MinidoracatMiniMap_GhostMode", false,
        "UI_MinidoracatMiniMap_GhostMode_tooltip")
    -- 穿透模式地圖不透明度（%）：_Ghost.lua dimMapBody 依值壓暗；改動經 apply 即時重壓
    modOptions:addSlider("GhostAlpha", "UI_MinidoracatMiniMap_GhostAlpha", 10, 90, 5, 40)
    -- 浮動開關圖標（預設開）：常駐畫面小圖標，點擊開關小地圖、拖曳移動（見檔尾一節）
    modOptions:addTickBox("FloatIcon", "UI_MinidoracatMiniMap_FloatIcon", true,
        "UI_MinidoracatMiniMap_FloatIcon_tooltip")
    -- 自訂尺寸（textentry，PZAPI/ModOptions.lua:40）：拖曳小地圖邊緣縮放時自動寫入。
    -- 不存 WorldMapSettings：它非泛用 key-value——setDouble 只認建構時註冊的
    -- ConfigOption，未知鍵靜默 no-op（WorldMapSettings.java:73-77、32-42），
    -- 故改用 ModOptions；做成可見欄位讓玩家能手動清空還原。
    modOptions:addTextEntry("CustomSize", "UI_MinidoracatMiniMap_CustomSize", "",
        "UI_MinidoracatMiniMap_CustomSize_tooltip")
    -- 浮動圖標位置（"x,y"）：拖曳圖標時自動寫入；同 CustomSize 做可見欄位可手動清空還原
    modOptions:addTextEntry("FloatIconPos", "UI_MinidoracatMiniMap_FloatIconPos", "",
        "UI_MinidoracatMiniMap_FloatIconPos_tooltip")

    -- 按「接受/套用」時由 MainOptions:apply 呼叫（3789）。該函式先跑 gameOptions:apply()
    -- （3787）把 UI 值寫回 option，所以此處 getValue() 已是新值。
    -- 無小地圖（主選單、沙盒未開 AllowMiniMap、尚未開圖）時只存值不動作。
    function modOptions:apply()
        -- 浮動圖標不依附小地圖視窗，先於下方小地圖防呆處理（內含無玩家檢查）；
        -- 實作在 MinidoracatMiniMap_FloatIcon.lua，nil 防呆＝模組缺失/版本檢查未過時略過
        if Core.updateFloatIconVisibility then Core.updateFloatIconVisibility() end
        if not getSpecificPlayer(0) then return end
        local cur = {
            imagery = getBoolOption("MapImagery", true) == true,
            packLayers = getBoolOption("MapPackLayers", true) == true,
            sizeIndex = getSizeIndex(),
            customSize = getCustomSizeRaw(),
        }
        -- ponytail: 只處理 player 0，分割畫面其餘玩家沿用原版（原版 saveSettings 也只存 player 0）
        local mm = getPlayerMiniMap(0)
        local plan = computeApplyPlan({
            worldImagery = appliedWorldImagery,
            hasMiniMap = mm ~= nil,
            imagery = mm and mm._minidoracatImagery,
            packLayers = mm and mm._minidoracatPackLayers,
            sizeIndex = mm and mm._minidoracatSizeIndex,
            customSize = mm and mm._minidoracatCustomSize,
        }, cur)
        -- 世界地圖側（不依賴小地圖存在——AllowMiniMap 關閉時亦可切換）：
        -- 開＝補掛、關＝逐 id 卸載（不走 Reapply Style，見 removeMiniMapPyramidLayers 註解）
        if plan.reapplyWorldMap and ISWorldMap_instance then
            if cur.imagery then
                pcall(applyMiniMapPyramids, ISWorldMap_instance)
            else
                pcall(removeMiniMapPyramidLayers, ISWorldMap_instance)
            end
            appliedWorldImagery = cur.imagery
        end
        if plan.clearCustomSize then
            -- 下拉改動＝快速重置：清掉自訂尺寸（之後引擎照常存 ModOptions.ini，
            -- MainOptions.lua:3793）
            local customOpt = self:getOption("CustomSize")
            if customOpt then customOpt:setValue("") end
        end
        if plan.recreate then
            ISMiniMap.Recreate(0) -- 掛載/建層/尺寸相關改動：重建一次套用全部
        elseif plan.live and mm.inner and mm.inner.mapAPI then
            applyToggleOptions(mm.inner.mapAPI) -- 純開關直接寫 mapAPI，即時生效
            applyChromeOpacity(mm) -- 外框不透明度亦即時生效
        end
        -- ZombieDots 免處理：繪製端每幀讀選項值，存檔即生效
        -- 穿透模式：ESC 勾選改動即時生效（事件 gate 每次讀值；此處套非事件面）。
        -- 不帶參數＝套所有現存小地圖：事件 gate 是 class 層全玩家生效，
        -- 非事件面也要全玩家收斂（分割畫面 P2+ 才不會旗標/視覺半套）
        if Core.applyGhost then pcall(Core.applyGhost) end
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
        raiseResizeMinForButtons() -- 先抬下限再夾 CustomSize（見該函式註解）
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
            minimap._minidoracatImagery = getBoolOption("MapImagery", true) -- 同上：圖片化總開關
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
            -- 穿透模式非事件面（consume 旗標/外框變淡）重建後重套（狀態跨重啟持久）
            if Core.applyGhost then pcall(Core.applyGhost, minimap) end
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
        if getBoolOption("GhostMode", false) then
            -- 穿透：標題列＋按鈕列強制收合（Ghost > AdornMode「永遠顯示」）——
            -- invisible 的按鈕群不吃事件，也是穿透覆蓋面的一環
            visible = false
        elseif isAdornAlways() then
            visible = true
        end
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
        { id = "PoiIcons", label = "UI_MinidoracatMiniMap_PoiIcons", default = true },
        { id = "StreetNames", label = "UI_MinidoracatMiniMap_StreetNames", default = true,
            apply = function(panel, selected)
                if panel.map and panel.map.mapAPI then
                    panel.map.mapAPI:setBoolean("ShowStreetNames", selected)
                end
            end },
        { id = "Safehouses", label = "UI_MinidoracatMiniMap_Safehouses", default = true },
        { id = "LockPosition", label = "UI_MinidoracatMiniMap_LockPosition", default = false },
        { id = "GhostMode", label = "UI_MinidoracatMiniMap_GhostMode", default = false,
            -- 三處設定面等價：此面也必須收斂到 applyGhost（漏掉＝旗標/變淡半套，
            -- 且 freelook 拖離中開穿透會卡在拖離處點不回中）
            apply = function() if Core.applyGhost then pcall(Core.applyGhost) end end },
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

    -- Zone 圖層總開關齒輪項（有「外部」zone provider 註冊才加；同 MapPack 動態追加模式）。
    -- 選項本體在下方 ESC/統一視窗的 OnGameBoot 註冊；此處只補齒輪面板這一面。
    Events.OnGameBoot.Add(function()
        if not hasExternalZoneProvider() then return end
        table.insert(GEAR_TICKS, { id = "ZoneLayer",
            label = "UI_MinidoracatMiniMap_ZoneLayer", default = true })
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
-- 按鈕列擴充（C＝回中、⚙＝設定視窗入口）
-- 統一設定視窗整節（UNIFIED_* 資料表、unifiedRebuild、buildSettingsWindow、
-- toggleSettingsWindow 等）已拆至 MinidoracatMiniMap_Settings.lua（Kahlua 每原型
-- locvar 上限 200 對策）；主檔僅留按鈕列與開窗入口，呼叫時查
-- Core.toggleSettingsWindow＋nil 防呆（模組檔載入序在本檔之後）。
--------------------------------------------------------------------------------
-- 按鈕列重排：7 顆（M - + C XY ⚙ X）以動態間距塞進 inner 寬度
-- （原版置中排版只按 5 顆算，ISMiniMap.lua:417）
local function relayoutBottomButtons(mm)
    local order = { mm.button1, mm.button2, mm.button3, mm._minidoracatCenterBtn,
        mm._minidoracatCopyBtn, mm.button4, mm.button6 }
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
    return n
end

-- 寫入系統剪貼簿＋座標列 1.5 秒琥珀「已複製」回饋（回饋獨立於 ShowPlayerCoords
-- 開關，見 drawPlayerCoords）。失敗記 log：點擊觸發非每幀路徑不會洗版，剪貼簿被
-- 其他程序鎖定/平台異常時可診斷（同 drawAnimalDots 的可診斷慣例）。Clipboard＝
-- 引擎全域（zombie.core.Clipboard static，LuaManager Exposer 無條件曝露；vanilla
-- 非 debug 用例 ISVersionWaterMark.lua:72）
local function copyCoordsText(inner, text)
    if not (Clipboard and Clipboard.setClipboard) then
        log("複製座標失敗: Clipboard 全域不可用")
        return
    end
    local ok, err = pcall(Clipboard.setClipboard, text)
    if not ok then
        log("複製座標失敗: " .. tostring(err))
    elseif inner then
        inner._minidoracatCopiedUntil = getTimestampMs() + 1500
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
    -- 「XY」複製玩家座標：格式 x,y,z（原版 /teleportto x,y,0 相容；vanilla 貼上端
    -- ISTeleportDebugUI 解析吃任意分隔符——但負號也被當分隔符，地下室負 z 貼回
    -- 原版傳送 UI 會解析失敗；此處保留真實 z 不謊報 0，限制註記於此）
    local copyBtn = ISButton:new(0, ref.y, ref.width, ref.height, "XY", mm, function(target)
        local playerObj = getSpecificPlayer(target.playerNum or 0)
        if not playerObj then return end
        copyCoordsText(target.inner, string.format("%d,%d,%d",
            math.floor(playerObj:getX()), math.floor(playerObj:getY()),
            math.floor(playerObj:getZ())))
    end)
    copyBtn:initialise()
    copyBtn.borderColor = { r = 0.4, g = 0.4, b = 0.4, a = 1 }
    copyBtn.tooltip = getText("UI_MinidoracatMiniMap_BtnCopyCoords")
    mm.bottomPanel:addChild(copyBtn)
    mm._minidoracatCopyBtn = copyBtn
    -- 「=」圖層面板鈕已退役：引擎原生三項移入統一視窗「圖層顯示」區。
    -- 原版面板機制（getVisibleOptions/onTickBox wrap 等）保留不拆——
    -- 面板已無入口，但第三方 MOD 若開啟它，注入與回寫仍正確
    mm.button4.tooltip = getText("UI_MinidoracatMiniMap_BtnSettings")
    -- 原版按鈕補 tooltip（M/-/+/X 原版無滑鼠提示；tooltip 欄位同上）
    if mm.button1 then mm.button1.tooltip = getText("UI_MinidoracatMiniMap_BtnWorldMap") end
    if mm.button2 then mm.button2.tooltip = getText("UI_MinidoracatMiniMap_BtnZoomOut") end
    if mm.button3 then mm.button3.tooltip = getText("UI_MinidoracatMiniMap_BtnZoomIn") end
    if mm.button6 then mm.button6.tooltip = getText("UI_MinidoracatMiniMap_BtnClose") end
    local n = relayoutBottomButtons(mm) or 7
    -- n 顆按鈕的最小可容寬度回寫尺寸下限（n＝order 表實際數量，單一來源）：UI 字型
    -- 放大時 BUTTON_HGT 跟著變大，動態墊高避免縮到溢出。InitPlayer 另以
    -- raiseResizeMinForButtons 在 CustomSize 夾限前先抬——本回寫發生在視窗建立後，
    -- 只服務「本 session 後續拖曳」的下限
    local minW = n * ref.width + (n - 1) * 2 + (mm.borderSize or 2) * 2 + 4
    if minW > RESIZE_MIN then RESIZE_MIN = minW end
    -- ponytail: C/XY 兩顆新鈕都未登記手把導航列（原版 insertNewLineOfButtons 於
    -- createChildren 一次性登記，事後補列會亂序）——手把用戶可從 ESC 選項頁控制
    -- 顯示開關，但複製功能手把不可達（滑鼠限定）；需要時再補登記
end

-- 齒輪改開設定視窗（本體拆至 MinidoracatMiniMap_Settings.lua，呼叫時查命名空間）；
-- 無 PZAPI（設定無處持久化）或模組缺失時維持原版行為（開圖層面板）
if ISMiniMapOuter and ISMiniMapOuter.onButton4 then
    local originalOnButton4 = ISMiniMapOuter.onButton4
    function ISMiniMapOuter:onButton4()
        if not (modOptions and Core.toggleSettingsWindow) then return originalOnButton4(self) end
        Core.toggleSettingsWindow(self)
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

-- 小地圖可視範圍的世界座標外接框：視窗四角 uiToWorld（2 參數版用例
-- ISMiniMap.lua:234-235）取 min/max——等軸測下視窗是世界座標裡的旋轉四邊形，
-- 外接框是超集，夠用；±2 格邊距容住取樣間隔內的移動。殭屍/動物取樣與
-- POI 圖標預裁共用。
-- 版本假設（42.20.2 反編譯查證）：WorldMapRenderer.calcMatrices 不吃 center 參數，
-- world↔UI 是純仿射、互為反函數，超集性質才恆成立；且原版 2 參 uiToWorldY
-- （UIWorldMapV1.java:295）把 centerWorldY 誤傳進 centerWorldX 位——現因 center
-- 不參與矩陣、Y 路徑不用 centerWorldX 而無害，上游若改（如加透視）本函式
-- Y 範圍會靜默失效。uiToWorld 與 worldToUI 兩方向都經
-- UIWorldMapV1:218-223/298-309 取 getModelViewProjectionMatrix() 同一份快取矩陣
-- （非 WorldMapRenderer 自身 calcMatrices 現算的 overload），故等軸測開關的
-- 175ms slerp 轉場期間互逆性照樣成立，無轉場閃爍問題。
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

-- 仿射投影快取：worldToUI 已由反編譯證明是純仿射（見 visibleWorldAABB 的版本
-- 假設——calcMatrices 為正交＋旋轉、無透視項），每 pass 只在視野中心採樣三點
-- 導出係數，其後所有矩形角用純 Lua 乘加取代逐點 2 次 Kahlua→Java 呼叫——
-- 區塊全開時視野內數百棟×8 次投影/棟是最大單一 CPU 成本。
-- 錨點取視野中心而非世界原點：引擎座標是 float32，錨距視野太遠會災難性消去。
-- 前移至此（原在 zone pass 區段）：殭屍/動物/載具繪製迴圈同用（ICON-1/2）。
-- test:derive-affine:start
local function deriveAffine(mapAPI, acx, acy)
    local p0x = mapAPI:worldToUIX(acx, acy)
    local p0y = mapAPI:worldToUIY(acx, acy)
    return p0x, p0y,
        mapAPI:worldToUIX(acx + 1, acy) - p0x,
        mapAPI:worldToUIY(acx + 1, acy) - p0y,
        mapAPI:worldToUIX(acx, acy + 1) - p0x,
        mapAPI:worldToUIY(acx, acy + 1) - p0y
end
-- test:derive-affine:end

-- test:zombie-sampling:start
local function sampleZombieDots(inner)
    local pn = inner.playerNum or 0
    local st = zdotsStateFor(inner)
    local dist = displayDist("ZombieDotDistance")
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

-- 物種/載具類別篩選定義（統一視窗勾選 UI＋取樣端篩選共用；CSV 存「停用」鍵、
-- 空字串＝全開）。鼠類 UI 上合併 rat+mouse（圖標也共用 map_rodent）。
-- 取樣端（adotsDisabledGroups/sampleAnimalDots）與 registerAnimalGroup 都讀寫，
-- 定義留在主檔；統一視窗（MinidoracatMiniMap_Settings.lua）經命名空間引用同一表
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

-- 物種 → 圖標素材。活鹿無物品圖（不可入包的動物只有屍體圖），物品風格用鹿屍圖；
-- 未知物種（其他 MOD 動物）→ 腳印備援。（統一視窗畫物種小圖經命名空間引用）
local ADOTS_ART = {
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
local function adotsTexture(name) -- 統一視窗物種小圖亦用（經命名空間引用）
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
        st.mask = nil
        st.da = nil
        st.dv = nil
        st.rawA = nil
        st.rawV = nil
        st.mode = nil
        st.errLogged = nil
    end
    local now = getTimestampMs()
    local da = displayDist("AnimalIconDistance")
    local dv = displayDist("VehicleIconDistance")
    local livestockMode = livestockVisibilityMode()
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
local adotsBodyACache = {} -- af→bodyA（ICON-4：sqrt 是跨界呼叫、原每圖標每幀一次；af 來自滑條離散值，鍵集有界）
local function adotsDrawGlyph(inner, tex, ux, uy, size, r, g, b, af)
    af = af or 1 -- 透明度係數（黑影/本體等比；統一視窗物種小圖等呼叫端可省略）
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
    local allowAnimals = sandboxGate("AllowAnimalDots", true) ~= false -- 伺服器沙盒閘門
    local wantWild = allowAnimals and getBoolOption(wildOpt, false)
    local wantLive = allowAnimals and getBoolOption(liveOpt, false)
    local wantVeh = getBoolOption(vehOpt, false)
        and sandboxGate("AllowVehicleDots", true) ~= false
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
    if st.count == 0 then return end
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
-- test:clipped-edge:start
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
-- a 省略＝沿用 SH_EDGE_A（安全屋/地圖框既有呼叫皆傳 7 參，行為不變）；
-- zone 框線傳入 borderAlpha 走此可選第 8 參
local function drawClippedEdge(inner, x1, y1, x2, y2, r, g, b, a)
    local cx1, cy1, cx2, cy2 = clipSegment(x1, y1, x2, y2, inner.width, inner.height)
    if cx1 then
        inner:drawLine(nil, cx1, cy1, cx2, cy2, 1, a or SH_EDGE_A, r, g, b)
    end
end
-- test:clipped-edge:end

-- test:safehouse-distance:start
local function drawSafehouses(inner)
    if not (SafeHouse and SafeHouse.getSafehouseList) then return end
    if not getBoolOption("Safehouses", true) then return end
    local dist = displayDist("SafehouseDisplayDistance")
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
-- 框線透明度倍率表：索引對應 MapBoundsAlpha 下拉順序，三檔語意與數值同小地圖
-- Opacity（CHROME_FACTORS）；乘在既有 alpha 上（框線基準 SH_EDGE_A、名稱底墊 0.6、
-- 名稱文字 0.95），第 1 檔＝1.0 保證預設外觀與加選項前逐位元相同
local MAPB_ALPHAS = { 1.0, 0.5, 0.15 }

local function drawMapBounds(inner)
    if #mapOverlays == 0 then return end
    if not getBoolOption("MapBounds", true) then return end
    local c = MAPB_COLORS[getComboIndex("MapBoundsColor", 1)] or MAPB_COLORS[1]
    local af = MAPB_ALPHAS[getComboIndex("MapBoundsAlpha", 1)] or 1.0
    local mapAPI = inner.mapAPI
    for i = 1, #mapOverlays do
        local ov = mapOverlays[i]
        local x1, y1, x2, y2 = ov.bounds[1], ov.bounds[2], ov.bounds[3], ov.bounds[4]
        local ux1, uy1 = mapAPI:worldToUIX(x1, y1), mapAPI:worldToUIY(x1, y1)
        local ux2, uy2 = mapAPI:worldToUIX(x2, y1), mapAPI:worldToUIY(x2, y1)
        local ux3, uy3 = mapAPI:worldToUIX(x2, y2), mapAPI:worldToUIY(x2, y2)
        local ux4, uy4 = mapAPI:worldToUIX(x1, y2), mapAPI:worldToUIY(x1, y2)
        drawClippedEdge(inner, ux1, uy1, ux2, uy2, c[1], c[2], c[3], SH_EDGE_A * af)
        drawClippedEdge(inner, ux2, uy2, ux3, uy3, c[1], c[2], c[3], SH_EDGE_A * af)
        drawClippedEdge(inner, ux3, uy3, ux4, uy4, c[1], c[2], c[3], SH_EDGE_A * af)
        drawClippedEdge(inner, ux4, uy4, ux1, uy1, c[1], c[2], c[3], SH_EDGE_A * af)
        -- 名稱：缺譯退 mod ID（慣例同齒輪面板 getTextOrNull(label) or id）；
        -- nameKey 為 nil 時不可傳入 getTextOrNull（Java 端 startsWith 會 NPE，
        -- Translator.java:324）。
        -- 名稱/寬/高首繪 memo 在 overlay 表（perf 稽核 MISC-1）：session 內不變，
        -- 原每 overlay 每幀付翻譯查找＋逐字形量測＋字高共 4 次跨界，且與可見性
        -- 無關；collectMapOverlays 重建 overlay 表即自然失效。
        -- （稽核另提投影仿射化：MapBounds 無世界預裁、遠角經仿射誤差隨距離放大，
        -- 裁線後窗內線段可能可見偏移——與 zone pass「僅投影近處」前提不同，不採）
        local name = ov._name
        if name == nil then
            name = (ov.nameKey and getTextOrNull(ov.nameKey)) or ov.mapMod or false
            ov._name = name
            if name then
                local tm = getTextManager()
                ov._tw = tm:MeasureStringX(UIFont.Small, name) -- 用例 ISFactionUI.lua:238
                ov._th = tm:getFontHeight(UIFont.Small) -- 字高隨 UI 字型倍率變動，不可硬編碼
            end
        end
        if name then
            local tw = ov._tw
            local th = ov._th
            local cx = (ux1 + ux3) / 2 - tw / 2 -- 菱形中心＝對角中點
            local cy = (uy1 + uy3) / 2 - th / 2
            if cx >= 2 and cy >= 2 and cx + tw <= inner.width - 2 and cy + th <= inner.height - 2 then
                inner:drawRect(cx - 3, cy - 1, tw + 6, th + 2, 0.6 * af, 0, 0, 0)
                inner:drawText(name, cx, cy, 1, 1, 1, 0.95 * af, UIFont.Small)
            end
        end
    end
end

--------------------------------------------------------------------------------
-- Zone 圖層（資料由 registerZoneProvider 的 addon 提供；本 MOD 只渲染）：
-- 分兩段插入以對齊 z-order——fillPass 走最底層（base map 之上、框線之下），
-- linePass（框線＋名稱）與 drawMapBounds 同層。無 provider 或全空表＝dormant 零成本。
-- 閘門 per-provider：外部 addon provider 受 ZoneLayer 總開關（關則跳過該 provider、
-- 不呼叫）；內部 provider（internal，如內建 POI）不受 ZoneLayer 連坐，由自家開關
-- 控制＋另受 POI 顯示距離閘（poiDistParams/zoneWithinDist——沙盒與玩家自訂距離）。
--------------------------------------------------------------------------------

-- 填色：每 rect 四角 worldToUIX/Y 投影（等軸測下矩形成菱形）→ 投影後 AABB 出視窗即略過
-- （DrawPolygon 不裁切、不查 isVisible，角落小地圖會畫出視窗外，研究 §1）→ drawPolygon
-- 純色填（⚠ 參數序 r,g,b,a）。整段包 setStencilRect/clearStencilRect 硬裁到元件矩形，
-- 兜住投影誤差與貼齊視窗邊的溢出（真 GPU stencil，ISUIElement.lua:459/475）。
-- test:zone-render:start
-- Zone provider 繪製錯誤 log-once：provider 是外部 addon，個別隔離後壞的不得拖垮整個
-- pass；依 owner 各記一次（沿用動物圖標 log-once 策略），旗標存 inner 實例
local function zoneProviderErrorOnce(inner, owner, err)
    local logged = inner._minidoracatZoneProviderErr
    if not logged then
        logged = {}
        inner._minidoracatZoneProviderErr = logged
    end
    if not logged[owner] then
        logged[owner] = true
        log("Zone provider draw failed (" .. tostring(owner) .. "): " .. tostring(err))
    end
end

-- 繪製本體拆出：drawZoneFill 用 pcall(具名函式) 包起免每幀配置閉包；stencil 開啟狀態
-- 記在 inner 實例，跨 pcall 邊界回傳給呼叫端做無條件清除（見 drawZoneFill 的 A1 保護）
-- 區塊縮放 LOD 檔位（px/世界格，mapAPI:getWorldScale()；原版標記同機制
-- WorldMapGridSquareMarker.java:45）：帶 lodRect 的 zone（POI）在
-- < HIDE 整區塊不畫（此縮放下區塊已是色點，只留圖標）、< DETAIL 畫聯集框
-- （一棟一框，2~3px/格下與逐房間視覺無異、成本 1/3）、>= DETAIL 逐房間
-- 平面圖＋名稱。無 lodRect 的 zone 不參與、任何縮放照畫（Zones addon 自
-- 0.2.x 起對建物尺度區域〔聯集最長邊 ≤100 格〕自動附 lodRect 進 LOD，
-- 大範圍區域仍不附、維持全縮放可見——見其 attachLodRect）。
local ZONE_LOD_HIDE = 1.5
local ZONE_LOD_DETAIL = 6
-- 區塊底襯外擴量（螢幕 px；/scale 換算世界格後走同一仿射投影）：haloAlpha zone
-- 於細節檔在每 rect 填色下方先畫外擴此值的暗色 quad——無框線的區塊靠這圈暗色
-- 描邊與地圖及相鄰區塊分界。以螢幕 px 定義使縮放下描邊視覺粗細恆定
local ZONE_HALO_PX = 2
local lodSingle = {} -- 中距離檔重用的單元素 rect 清單（避免每 zone 每幀配置）
-- 圖標去重疊格（generation 標記免清表）：中/遠距下 lodRect zone 的圖標在同一
-- 「圖標尺寸」螢幕格內只畫第一顆——拉遠時數百顆互疊的圖標是遠距檔最大殘餘
-- 成本（每顆 1 次 drawTextureScaled Java 呼叫），疊在同格的視覺上也不可分辨
local iconGrid = {}
local iconGridGen = 0
-- zone 名稱寬度快取（ZR-4，lines pass 用）：key＝名稱字串。renderer 自有——
-- provider 回傳表是只讀契約，不得把快取寫進去
local zoneNameWidth = {}

-- POI 顯示距離閘（沙盒 PoiDisplayDistance＋全域上限＋玩家自訂，經 displayDist
-- 合成取最小正值）：只作用於 internal provider（內建 POI），外部 addon zone
-- （地圖包範圍框線等）不受影響。語意近安全屋距離閘——資源點矩形（顯示中的
-- 分類房間）最近點距玩家 N 格內才顯示；二維、不計樓層。回傳 px, py, dist²
-- （未啟用時 dist²=nil＝全放行）與 blocked（距離啟用但缺玩家：fail closed，
-- 內部 provider 整段不畫——同 drawSafehouses 的缺玩家語意）。
local function poiDistParams(inner)
    local dist = displayDist("PoiDisplayDistance")
    if not dist then return nil, nil, nil, false end
    local playerObj = getSpecificPlayer(inner.playerNum or 0)
    if not playerObj then return nil, nil, nil, true end
    return playerObj:getX(), playerObj:getY(), dist * dist, false
end

-- 玩家點到矩形最近點的距離平方；夾限用純 Lua 比較而非 math.max/min——Kahlua
-- 下庫函式是 JavaFunction，每 zone 多次跨界呼叫在預裁前發生、全圖 ~1692 筆
-- ×1~3 pass 會積成可觀成本
local function rectDist2(rc, px, py)
    local dx = px < rc.x1 and (rc.x1 - px) or (px > rc.x2 and (px - rc.x2) or 0)
    local dy = py < rc.y1 and (rc.y1 - py) or (py > rc.y2 and (py - rc.y2) or 0)
    return dx * dx + dy * dy
end

-- zone 是否落在距離內：逐矩形判距，任一資源點矩形最近點在 N 格內即顯示。量測對象
-- ＝distRects（有給）否則 rects——POI 整棟外框模式畫整棟框但仍量分類房間，使該
-- 外觀開關不改變可見距離。⚠ lodRect 不是整棟建築 bbox，逐房間模式下是分類房間
-- 聯集的 AABB（大型建物的分類房間可能只佔一角，AABB 也含無房間的空白區——
-- codex review 以實資料證明兩者可差數十格），故僅作快速排除：點到 AABB 的距離
-- 是點到任一內含矩形距離的下界，AABB 超距＝全部超距，免逐矩形。此下界對
-- distRects 同樣成立（房間矩形恆在整棟框內，實測 1692 筆全數滿足）。無矩形者放行
-- （後續本就無物可畫）。呼叫端以 pdist2 短路（閘未啟用零成本）；fill/lines/icons
-- 三 pass 同一判定，整 zone 一致顯隱。
local function zoneWithinDist(z, px, py, dist2)
    local lod = z.lodRect
    if lod and rectDist2(lod, px, py) > dist2 then return false end
    -- distRects（選配）覆寫量測對象：POI 整棟外框模式下畫的是整棟框，但可見距離
    -- 該由「資源點本身」決定——外框只是外觀選項，不該讓大型建物提早數十格解鎖
    -- （lodRect 仍是有效下界：房間矩形恆在整棟框內，AABB 超距即全部超距）
    local rects = z.distRects or z.rects
    local n = rects and #rects or 0
    if n == 0 then return true end
    for i = 1, n do
        if rectDist2(rects[i], px, py) <= dist2 then return true end
    end
    return false
end

local function drawZoneFillBody(inner)
    local mapAPI = inner.mapAPI
    local w, h = inner.width, inner.height
    local scale = mapAPI:getWorldScale()
    -- 視野預裁（同 drawZoneIcons，v3 後區塊模式數千矩形×8 次投影/幀會壓垮
    -- FPS）：世界座標 AABB 不相交者直接跳過，連投影都不做——外接框是視窗
    -- 超集，被裁者投影後必在窗外、原本的螢幕裁切也不會畫，逐像素不變。
    -- 退化行為：uiToWorld 未就緒回 0.0F 時外接框塌縮＝fill/line 也整幀全裁，
    -- 與圖標 pass 同退化（舊碼該情況同樣什麼都畫不出，見 icons pass 論證）
    local vMinX, vMaxX, vMinY, vMaxY = visibleWorldAABB(inner)
    local acx = math.floor((vMinX + vMaxX) / 2)
    local acy = math.floor((vMinY + vMaxY) / 2)
    local p0x, p0y, sxx, sxy, syx, syy = deriveAffine(mapAPI, acx, acy)
    local ppx, ppy, pdist2, poiBlocked = poiDistParams(inner)
    for pi = 1, #registeredZoneProviders do
        local provider = registeredZoneProviders[pi]
        -- 閘門：外部 provider 受 ZoneLayer 總閘（internal 不受）＋ per-provider 母開關
        -- （optionKey 有給才 gate）；內部 provider 另受 POI 顯示距離閘（沙盒
        -- PoiDisplayDistance／全域上限 AllInfoDistance＋玩家自訂，見 poiDistParams；
        -- 缺玩家 fail closed 整段跳過）；任一關則 pok 留 nil、整段跳過
        local pok, zones
        if not (provider.internal and poiBlocked)
            and (provider.internal or getBoolOption("ZoneLayer", true))
            and (not provider.optionKey or getBoolOption(provider.optionKey, true)) then
            -- A2：每個 provider 個別 pcall，壞的跳過續跑下一個（附 owner，log-once）
            pok, zones = pcall(provider.fn)
        end
        if pok == false then
            zoneProviderErrorOnce(inner, provider.owner, zones)
        -- hasFill 聚合旗標（perf 稽核 ZR-1）：false＝provider 聲明本 pass 無可畫
        -- 內容，整段跳過（預設純圖標模式下省每幀全 zone 空掃）；nil＝未聲明
        -- （外部 addon），照舊逐 zone 判斷
        elseif type(zones) == "table" and zones.hasFill ~= false then
            for zi = 1, #zones do
                local z = zones[zi]
                local fill, rects = z.fill, z.rects
                local lod = z.lodRect
                -- fillAlpha==0（如 POI 圖標模式）早退，連投影都省；LOD 拉遠檔整區不畫；
                -- 內部 provider 的 zone 另過 POI 距離閘（not pdist2 先行短路：閘未啟用
                -- ——絕大多數玩家的預設——不付逐 zone 函式呼叫）
                if fill and rects and z.fillAlpha ~= 0
                    and not (lod and scale < ZONE_LOD_HIDE)
                    and (not pdist2 or not provider.internal or zoneWithinDist(z, ppx, ppy, pdist2)) then
                    local a = z.fillAlpha or 0.2
                    local rn = #rects
                    if lod and scale < ZONE_LOD_DETAIL then
                        lodSingle[1] = lod
                        rects, rn = lodSingle, 1
                    end
                    -- 底襯 pass（haloAlpha，細節檔限定）：先畫全部外擴暗色 quad、再畫
                    -- 全部填色——分兩圈使同 zone 相鄰矩形（L 形建物）的內部接縫被後畫
                    -- 的填色蓋掉，暗邊只留在區塊外緣；跨 zone 的暗邊蓋在先畫的鄰棟填色
                    -- 上，正是要的分界。成本每 rect 1 次 drawPolygon（stencil 裁切、
                    -- 零 Lua 裁線），遠低於舊框線的 4 條 drawClippedEdge；中距檔不畫
                    -- （城市尺度 fill 是效能熱點，該檔位維持純填色零新增成本）
                    local halo = z.haloAlpha
                    if halo and halo > 0 and scale >= ZONE_LOD_DETAIL then
                        local wpad = ZONE_HALO_PX / scale
                        for ri = 1, rn do
                            local rc = rects[ri]
                            local hx1, hy1 = rc.x1 - wpad, rc.y1 - wpad
                            local hx2, hy2 = rc.x2 + wpad, rc.y2 + wpad
                            if hx2 >= vMinX and hx1 <= vMaxX and hy2 >= vMinY and hy1 <= vMaxY then
                                local dx1, dy1 = hx1 - acx, hy1 - acy
                                local dx2, dy2 = hx2 - acx, hy2 - acy
                                local ux1, uy1 = p0x + dx1 * sxx + dy1 * syx, p0y + dx1 * sxy + dy1 * syy
                                local ux2, uy2 = p0x + dx2 * sxx + dy1 * syx, p0y + dx2 * sxy + dy1 * syy
                                local ux3, uy3 = p0x + dx2 * sxx + dy2 * syx, p0y + dx2 * sxy + dy2 * syy
                                local ux4, uy4 = p0x + dx1 * sxx + dy2 * syx, p0y + dx1 * sxy + dy2 * syy
                                -- 純 Lua min/max 比較鏈（ZR-2：math.* 在 Kahlua 是 JavaFunction
                                -- 跨界呼叫——rectDist2 既有先例；每個過預裁 rect 省 4 次跨界）
                                local minx, maxx = ux1, ux1
                                if ux2 < minx then minx = ux2 elseif ux2 > maxx then maxx = ux2 end
                                if ux3 < minx then minx = ux3 elseif ux3 > maxx then maxx = ux3 end
                                if ux4 < minx then minx = ux4 elseif ux4 > maxx then maxx = ux4 end
                                local miny, maxy = uy1, uy1
                                if uy2 < miny then miny = uy2 elseif uy2 > maxy then maxy = uy2 end
                                if uy3 < miny then miny = uy3 elseif uy3 > maxy then maxy = uy3 end
                                if uy4 < miny then miny = uy4 elseif uy4 > maxy then maxy = uy4 end
                                if maxx >= 0 and minx <= w and maxy >= 0 and miny <= h then
                                    if not inner._minidoracatZoneStencilOn then
                                        inner:setStencilRect(0, 0, w, h)
                                        inner._minidoracatZoneStencilOn = true
                                    end
                                    inner:drawPolygon(nil, ux1, uy1, ux2, uy2, ux3, uy3, ux4, uy4,
                                        0, 0, 0, halo)
                                end
                            end
                        end
                    end
                    for ri = 1, rn do
                        local rc = rects[ri]
                        if rc.x2 >= vMinX and rc.x1 <= vMaxX and rc.y2 >= vMinY and rc.y1 <= vMaxY then
                            local dx1, dy1 = rc.x1 - acx, rc.y1 - acy
                            local dx2, dy2 = rc.x2 - acx, rc.y2 - acy
                            local ux1, uy1 = p0x + dx1 * sxx + dy1 * syx, p0y + dx1 * sxy + dy1 * syy
                            local ux2, uy2 = p0x + dx2 * sxx + dy1 * syx, p0y + dx2 * sxy + dy1 * syy
                            local ux3, uy3 = p0x + dx2 * sxx + dy2 * syx, p0y + dx2 * sxy + dy2 * syy
                            local ux4, uy4 = p0x + dx1 * sxx + dy2 * syx, p0y + dx1 * sxy + dy2 * syy
                            -- 純 Lua min/max 比較鏈（ZR-2，同 halo 段註解）
                            local minx, maxx = ux1, ux1
                            if ux2 < minx then minx = ux2 elseif ux2 > maxx then maxx = ux2 end
                            if ux3 < minx then minx = ux3 elseif ux3 > maxx then maxx = ux3 end
                            if ux4 < minx then minx = ux4 elseif ux4 > maxx then maxx = ux4 end
                            local miny, maxy = uy1, uy1
                            if uy2 < miny then miny = uy2 elseif uy2 > maxy then maxy = uy2 end
                            if uy3 < miny then miny = uy3 elseif uy3 > maxy then maxy = uy3 end
                            if uy4 < miny then miny = uy4 elseif uy4 > maxy then maxy = uy4 end
                            if maxx >= 0 and minx <= w and maxy >= 0 and miny <= h then
                                if not inner._minidoracatZoneStencilOn then
                                    inner:setStencilRect(0, 0, w, h)
                                    inner._minidoracatZoneStencilOn = true
                                end
                                inner:drawPolygon(nil, ux1, uy1, ux2, uy2, ux3, uy3, ux4, uy4,
                                    fill.r, fill.g, fill.b, a)
                            end
                        end
                    end
                end
            end
        end
    end
end

local function drawZoneFill(inner)
    if #registeredZoneProviders == 0 then return end
    inner._minidoracatZoneStencilOn = false
    -- A1：繪製本體整段包 pcall，clearStencilRect 於其後無條件執行——setStencilRect 後
    -- 任何繪製/provider 錯誤都不得漏掉 clear，否則引擎全域 stencilLevel 洩漏（set 未配對
    -- clear）→ 當幀後續 UI 持續被小地圖矩形裁切
    local ok, err = pcall(drawZoneFillBody, inner)
    if inner._minidoracatZoneStencilOn then inner:clearStencilRect() end
    -- clear 已保證執行後，把繪製錯誤交回呼叫端 safeDrawZone 的 log-once（保留原行為）
    if not ok then error(err, 0) end
end

-- 框線＋名稱：複用 drawClippedEdge（Liang-Barsky Lua 裁切）畫每 rect 四邊；
-- 名稱仿 drawMapBounds 置中畫法（畫在第一個 rect 中心；⚠ drawRect 參數序 a,r,g,b）
local function drawZoneLines(inner)
    if #registeredZoneProviders == 0 then return end
    local mapAPI = inner.mapAPI
    local w, h = inner.width, inner.height
    local tm = getTextManager()
    local th = tm:getFontHeight(UIFont.Small)
    local scale = mapAPI:getWorldScale()
    -- 視野預裁（同 drawZoneFillBody）：世界座標不相交者跳過投影
    local vMinX, vMaxX, vMinY, vMaxY = visibleWorldAABB(inner)
    local acx = math.floor((vMinX + vMaxX) / 2)
    local acy = math.floor((vMinY + vMaxY) / 2)
    local p0x, p0y, sxx, sxy, syx, syy = deriveAffine(mapAPI, acx, acy)
    local ppx, ppy, pdist2, poiBlocked = poiDistParams(inner)
    for pi = 1, #registeredZoneProviders do
        local provider = registeredZoneProviders[pi]
        -- 閘門（同 drawZoneFill）：外部受 ZoneLayer 總閘＋per-provider 母開關；internal
        -- 不受，但另受 POI 顯示距離閘（沙盒＋全域上限＋玩家自訂；缺玩家 fail closed）
        local pok, zones
        if not (provider.internal and poiBlocked)
            and (provider.internal or getBoolOption("ZoneLayer", true))
            and (not provider.optionKey or getBoolOption(provider.optionKey, true)) then
            -- A2：每個 provider 個別 pcall，壞的跳過續跑下一個（附 owner，log-once）
            pok, zones = pcall(provider.fn)
        end
        if pok == false then
            zoneProviderErrorOnce(inner, provider.owner, zones)
        elseif type(zones) == "table" and zones.hasLine ~= false then -- ZR-1（同 fill pass）
            for zi = 1, #zones do
                local z = zones[zi]
                local border, rects = z.border, z.rects
                local lod = z.lodRect
                -- 框線與名稱解耦：borderAlpha==0 只代表「不畫框」，不該連坐名稱——
                -- POI 區塊模式是純色塊＋名稱（無框線），Zones addon 也允許
                -- borderAlpha=0 而其 name 是必填欄位。本段兩件事各自的條件：
                --   框線 → drawEdges（有 border 且 alpha 非 0）
                --   名稱 → z.name（下方另有細節檔與螢幕裁切判定）
                -- 兩者皆無則整段跳過。LOD zone 的框線與名稱都僅細節檔畫（中距的
                -- 聯集框純填色——該縮放下框線是雜訊、名稱會洗版）；內部 provider
                -- 另過 POI 距離閘（not pdist2 先行短路，閘未啟用不付逐 zone 呼叫）
                local drawEdges = border and z.borderAlpha ~= 0
                if rects and (drawEdges or z.name)
                    and not (lod and scale < ZONE_LOD_DETAIL)
                    and (not pdist2 or not provider.internal or zoneWithinDist(z, ppx, ppy, pdist2)) then
                    local r, g, b, a
                    if drawEdges then r, g, b, a = border.r, border.g, border.b, z.borderAlpha end
                    local zoneVisible = false
                    -- name-only zone（POI 區塊模式）免整組 quad 投影（ZR-4）：名稱的
                    -- 繪製條件（標籤完整落窗內，見下方界檢）嚴格強於 zoneVisible，
                    -- 以 rects[1] 的世界預裁充當 zoneVisible 即可——輸出逐像素不變。
                    -- rects[1] 判 nil：空 rects（外部 addon 可給）靜默跳過，不得
                    -- nil 解參考打死整個 pass（codex review mutation probe 實證）。
                    -- 註：舊碼此處有 lod+中距→lodSingle 的分支，但上面的 gate 已排除
                    -- 「有 lod 且 scale < DETAIL」，該分支永不成立，隨改寫刪去
                    if not drawEdges then
                        local rc0 = rects[1]
                        zoneVisible = rc0 ~= nil and rc0.x2 >= vMinX and rc0.x1 <= vMaxX
                            and rc0.y2 >= vMinY and rc0.y1 <= vMaxY
                    end
                    local rn = drawEdges and #rects or 0
                    for ri = 1, rn do
                        local rc = rects[ri]
                        -- 世界座標預裁（被裁者投影後必在窗外，zoneVisible 語意不變）
                        if rc.x2 >= vMinX and rc.x1 <= vMaxX and rc.y2 >= vMinY and rc.y1 <= vMaxY then
                            local dx1, dy1 = rc.x1 - acx, rc.y1 - acy
                            local dx2, dy2 = rc.x2 - acx, rc.y2 - acy
                            local ux1, uy1 = p0x + dx1 * sxx + dy1 * syx, p0y + dx1 * sxy + dy1 * syy
                            local ux2, uy2 = p0x + dx2 * sxx + dy1 * syx, p0y + dx2 * sxy + dy1 * syy
                            local ux3, uy3 = p0x + dx2 * sxx + dy2 * syx, p0y + dx2 * sxy + dy2 * syy
                            local ux4, uy4 = p0x + dx1 * sxx + dy2 * syx, p0y + dx1 * sxy + dy2 * syy
                            -- A3：投影後 AABB 早退（同 drawZoneFill）——略過離屏 rect 的
                            -- clipSegment＋drawLine；zoneVisible 記住至少一 rect 落在視窗內
                            -- 純 Lua min/max 比較鏈（ZR-2，同 halo 段註解）
                            local minx, maxx = ux1, ux1
                            if ux2 < minx then minx = ux2 elseif ux2 > maxx then maxx = ux2 end
                            if ux3 < minx then minx = ux3 elseif ux3 > maxx then maxx = ux3 end
                            if ux4 < minx then minx = ux4 elseif ux4 > maxx then maxx = ux4 end
                            local miny, maxy = uy1, uy1
                            if uy2 < miny then miny = uy2 elseif uy2 > maxy then maxy = uy2 end
                            if uy3 < miny then miny = uy3 elseif uy3 > maxy then maxy = uy3 end
                            if uy4 < miny then miny = uy4 elseif uy4 > maxy then maxy = uy4 end
                            if maxx >= 0 and minx <= w and maxy >= 0 and miny <= h then
                                zoneVisible = true
                                if drawEdges then
                                    drawClippedEdge(inner, ux1, uy1, ux2, uy2, r, g, b, a)
                                    drawClippedEdge(inner, ux2, uy2, ux3, uy3, r, g, b, a)
                                    drawClippedEdge(inner, ux3, uy3, ux4, uy4, r, g, b, a)
                                    drawClippedEdge(inner, ux4, uy4, ux1, uy1, r, g, b, a)
                                end
                            end
                        end
                    end
                    -- 名稱畫在第一個 rect 的中心，僅中心落在視窗內才畫（同 drawMapBounds）；
                    -- 整區離屏（無 rect 在窗內）連名稱測量都省——名稱中心落在窗內必然使該
                    -- rect AABB 與視窗相交，故 zoneVisible 為真，不影響應畫的名稱
                    local name = z.name
                    local rc = rects[1]
                    -- 名稱僅細節檔顯示（lodRect zone；20 類全開時中/遠距的名稱洗版即此治）
                    if name and rc and zoneVisible
                        and (not lod or scale >= ZONE_LOD_DETAIL) then
                        -- 量測惰性快取（ZR-4）：renderer 自有、以名稱字串為 key——
                        -- 不得寫回 provider 的 zone 表（API 明定對回傳只讀不改；寫入
                        -- 會與 addon 同名欄位碰撞、對 __newindex 保護表拋錯，codex
                        -- review 抓出）。鍵集有界（POI 20 類名＋伺服器區域名，隨
                        -- zone 總量上限）；addon 改 z.name 換字串＝新 key，自然正確；
                        -- 字型倍率改動 PZ 慣例需重啟
                        local tw = zoneNameWidth[name]
                        if not tw then
                            tw = tm:MeasureStringX(UIFont.Small, name)
                            zoneNameWidth[name] = tw
                        end
                        local cxw, cyw = (rc.x1 + rc.x2) / 2, (rc.y1 + rc.y2) / 2
                        local cx = p0x + (cxw - acx) * sxx + (cyw - acy) * syx - tw / 2
                        local cy = p0y + (cxw - acx) * sxy + (cyw - acy) * syy - th / 2
                        if cx >= 2 and cy >= 2 and cx + tw <= inner.width - 2 and cy + th <= inner.height - 2 then
                            inner:drawRect(cx - 3, cy - 1, tw + 6, th + 2, 0.6, 0, 0, 0)
                            inner:drawText(name, cx, cy, 1, 1, 1, 0.95, UIFont.Small)
                        end
                    end
                end
            end
        end
    end
end

-- Zone 繪製呼叫端共用：pcall 包裹＋首次錯誤記 log（同動物圖標 log-once 策略）——
-- provider 是外部 addon 程式碼，拋錯不得拖垮整張地圖 prerender；旗標記在 inner 實例上
local function safeDrawZone(inner, fn, flagKey)
    local ok, err = pcall(fn, inner)
    if not ok and not inner[flagKey] then
        inner[flagKey] = true
        log("Zone layer draw failed: " .. tostring(err))
    end
end

-- 圖標 pass（與 linePass 同層）：zone 帶 icon={tex,r,g,b} 時，每 rect 中心投影，
-- 中心點落在視窗內才畫 18px 染色圖標（DrawTextureScaled 引數序 tex,x,y,w,h,a,r,g,b——
-- 同 adotsDrawGlyph 的白剪影染色手法；tex 由 provider 於建快取時 getTexture 解好，
-- 未齊者 icon 留 nil，這裡自然跳過）。fill/line/icon 三 pass 對 ZoneLayer/per-provider
-- 母開關的閘門一致。
local function drawZoneIcons(inner)
    if #registeredZoneProviders == 0 then return end
    local mapAPI = inner.mapAPI
    local w, h = inner.width, inner.height
    -- 大小/透明度滑條每幀讀值（0.9.0；作用於所有 zone 圖標，POI 為主）；
    -- 18＝滑條預設（同 ESC 頁 addSlider 預設值）
    local s = getSliderValue("PoiIconSize", 18, 8, 48)
    local ia = getSliderValue("PoiIconAlpha", 100, 10, 100) / 100
    local half = s / 2
    -- 中/遠距（<細節檔）對 lodRect zone 啟用圖標去重疊；細節檔全畫
    local declutter = mapAPI:getWorldScale() < ZONE_LOD_DETAIL
    iconGridGen = iconGridGen + 1
    -- 視野預裁（POI 擴至 ~1700 筆後，逐 rect 先投影再裁會付 ~3.4k 次/幀的
    -- Kahlua→Java worldToUI 呼叫）：先取一次可視世界外接框，rect 與框不相交者
    -- 直接跳過。框是視窗四邊形的超集，被裁者其 rect 中心必在窗外，而下方螢幕
    -- 裁切要求中心深入視窗 half+1px 才畫——預裁純省投影、不改變畫面；此論證
    -- 依賴「繪製 ⇒ 中心在窗內」，若日後放寬成「圖標矩形相交即畫」預裁即失效。
    -- 兩表面相容依據：ISWorldMap.lua:268 與 ISMiniMap.lua:192 同走 getAPIv3()，
    -- V3⊂V2⊂V1，2 參 uiToWorldX/Y 是 UIWorldMapV1.java:286-296 同一份繼承實作；
    -- 資料未就緒時回 0.0F 不丟例外（與 worldToUI 同守衛），退化為全裁＝與舊碼
    -- 的全裁行為一致。回歸測試見 scripts/test_zone_render.lua A5。
    local vMinX, vMaxX, vMinY, vMaxY = visibleWorldAABB(inner)
    local acx = math.floor((vMinX + vMaxX) / 2)
    local acy = math.floor((vMinY + vMaxY) / 2)
    local p0x, p0y, sxx, sxy, syx, syy = deriveAffine(mapAPI, acx, acy)
    local ppx, ppy, pdist2, poiBlocked = poiDistParams(inner)
    for pi = 1, #registeredZoneProviders do
        local provider = registeredZoneProviders[pi]
        -- 閘門（同 drawZoneFill）：外部受 ZoneLayer 總閘＋per-provider 母開關；internal
        -- 不受，但另受 POI 顯示距離閘（沙盒＋全域上限＋玩家自訂；缺玩家 fail closed）
        local pok, zones
        if not (provider.internal and poiBlocked)
            and (provider.internal or getBoolOption("ZoneLayer", true))
            and (not provider.optionKey or getBoolOption(provider.optionKey, true)) then
            pok, zones = pcall(provider.fn)
        end
        if pok == false then
            zoneProviderErrorOnce(inner, provider.owner, zones)
        elseif type(zones) == "table" and zones.hasIcon ~= false then -- ZR-1（同 fill pass）
            for zi = 1, #zones do
                local z = zones[zi]
                local icon, rects = z.icon, z.rects
                -- 內部 provider 的 zone 過 POI 距離閘（與 fill/lines 同判定，整棟一致
                -- 顯隱；not pdist2 先行短路——閘未啟用不付逐 zone 呼叫）
                if icon and icon.tex and rects
                    and (not pdist2 or not provider.internal or zoneWithinDist(z, ppx, ppy, pdist2)) then
                    -- iconOnce（POI v3 逐房間矩形）：圖標只畫在 rects[1]（provider
                    -- 保證是最大房間），避免一棟 200+ 房間疊 200 顆圖標；預裁與
                    -- 螢幕裁切照常作用於該矩形。選配 iconRect 覆寫第一顆的錨點
                    -- （POI 整棟外框模式：框是整棟、圖標仍釘在最大房間）
                    local rn = z.iconOnce and 1 or #rects
                    for ri = 1, rn do
                        -- iconRect 四欄齊備才採用，否則回退 rects[ri]：這是新公開的
                        -- 選配欄位，殘缺表（如 { x1 = 40 }）會在下方比較時 nil 比數字
                        -- 拋錯，而 safeDrawZone 包的是整個 pass——一個壞 addon 會讓當幀
                        -- 所有 provider 的圖標全滅（codex review）
                        local ir = ri == 1 and z.iconRect or nil
                        local rc = rects[ri]
                        if ir and ir.x1 and ir.y1 and ir.x2 and ir.y2 then rc = ir end
                        -- rc 判 nil：iconOnce＋空 rects（外部 addon 可給）時 rn=1 但
                        -- rects[1]=nil，缺守衛會 nil deref 打死整幀所有 provider 的圖標
                        if rc and rc.x2 >= vMinX and rc.x1 <= vMaxX and rc.y2 >= vMinY and rc.y1 <= vMaxY then
                            local cxw, cyw = (rc.x1 + rc.x2) / 2, (rc.y1 + rc.y2) / 2
                            local cx = p0x + (cxw - acx) * sxx + (cyw - acy) * syx
                            local cy = p0y + (cxw - acx) * sxy + (cyw - acy) * syy
                            -- 整矩形裁切（同動物圖標 :2670 手法，留 1px 邊）：只查中心會讓
                            -- 圖標半寬溢出地圖框（codex review 抓出）
                            local ix, iy = cx - half, cy - half
                            if ix >= 1 and iy >= 1 and ix + s <= w - 1 and iy + s <= h - 1 then
                                local ok = true
                                if declutter and z.lodRect then
                                    -- 同格已有圖標＝視覺不可分辨，跳過繪製；gen 標記
                                    -- 免逐幀清表。細節檔（declutter=false）全畫
                                    -- ZR-2 純 Lua floor（cx/cy 經螢幕界檢後恆正；s 為整數
                                    -- 滑條值，% 是 VM opcode 非跨界，恆等式對整數 s 精確）
                                    local gkey = ((cx - cx % s) / s) * 100000 + (cy - cy % s) / s
                                    if iconGrid[gkey] == iconGridGen then
                                        ok = false
                                    else
                                        iconGrid[gkey] = iconGridGen
                                    end
                                end
                                if ok then
                                    inner:drawTextureScaled(icon.tex, ix, iy, s, s,
                                        ia, icon.r, icon.g, icon.b)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end
-- test:zone-render:end

-- 世界地圖（M）同步畫框線：wrap prerender（原版 prerender＝ISWorldMap.lua:363）。
-- 時序同小地圖側（ISMiniMapInner:prerender）：引擎地圖畫在底、Lua prerender 疊加
-- 於其上，子元件（按鈕列/圖例/符號面板）之後才畫、蓋在最上——框線不遮 UI 控件
--（掛 render 會畫在子元件之後、蓋住按鈕列）。
if ISWorldMap and ISWorldMap.prerender then
    local originalWorldMapPrerender = ISWorldMap.prerender
    function ISWorldMap:prerender()
        -- Zone 填色置於 wrap 最前端＝最底層：Java 地圖本體早在 Lua prerender 前畫完
        -- （UIWorldMap.java:152→317），置頂即壓在 base map 之上、動物圖標與框線之下
        safeDrawZone(self, drawZoneFill, "_minidoracatWMZoneFillErrLogged")
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
        safeDrawZone(self, drawZoneLines, "_minidoracatWMZoneLineErrLogged") -- 與 MapBounds 同層
        safeDrawZone(self, drawZoneIcons, "_minidoracatWMZoneIconErrLogged") -- POI 圖標，同層
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
            -- Core.toggleSettingsWindow＝Settings 模組檔提供；缺席（模組缺失）就不插鈕
            if not (modOptions and Core.toggleSettingsWindow and self.buttonPanel and self.closeBtn) then return end
            local btnSize = self.closeBtn.height
            local btn = ISButton:new(self.closeBtn.x, 0, btnSize, btnSize, "", self,
                function(target) Core.toggleSettingsWindow(target) end)
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

-- 世界地圖（M）選項面板注入「圖片化地圖」勾選：與統一視窗/ESC 選項頁同一
-- MapImagery 選項（三面同源）。面板屬世界地圖單例、非每次開圖重建——tick 以
-- prerender 每幀讀值同步（setSelected 不觸發回呼），統一視窗/ESC 改動不脫鉤。
-- 佈局沿原版 WorldMapOptions:createChildren 尾段做法：附加於最底、重算視窗尺寸
-- （BUTTON_HGT/UI_BORDER_SPACING 是 ISWorldMap.lua 檔內 local，這裡自算字高/間距）
if WorldMapOptions and WorldMapOptions.createChildren then
    local originalWMOptCreateChildren = WorldMapOptions.createChildren
    function WorldMapOptions:createChildren()
        originalWMOptCreateChildren(self)
        -- pcall 邊界：同爪印鈕——例外外洩會沿 createChildren 炸掉世界地圖，
        -- 失敗只該損失這顆勾選（統一視窗/ESC 仍是入口）
        local ok, err = pcall(function()
            -- 冪等以「現任子元件」為準：原版 synchUI 於螢幕高度/debug 狀態變化時
            -- 清空 children 重跑 createChildren，self 欄位會殘留、以欄位判斷會
            -- 漏重插（codex review 抓出）
            for _, child in pairs(self:getChildren()) do
                if child._minidoracatImageryTick then return end
            end
            if not modOptions then return end
            local fontH = getTextManager():getFontHeight(UIFont.Small)
            local bottom = 0
            for _, child in pairs(self:getChildren()) do
                bottom = math.max(bottom, child:getBottom())
            end
            local tick = ISTickBox:new(11, bottom + 6, self.width, fontH + 4, "", self,
                function(target, index, selected)
                    -- settingsApply 同構（該函式是 Settings 模組內 local）：
                    -- setValue → apply（雙表面重建/卸載）→ save 落盤
                    local opt = modOptions:getOption("MapImagery")
                    if not opt then return end
                    opt:setValue(selected and true or false)
                    if modOptions.apply then modOptions:apply() end
                    PZAPI.ModOptions:save()
                end)
            tick:initialise()
            tick:addOption(getText("UI_MinidoracatMiniMap_MapImagery"))
            tick:setSelected(1, getBoolOption("MapImagery", true) and true or false)
            tick:setWidthToFit()
            self:addChild(tick)
            local origTickPrerender = tick.prerender
            function tick:prerender()
                self:setSelected(1, getBoolOption("MapImagery", true) and true or false)
                origTickPrerender(self)
            end
            tick._minidoracatImageryTick = true -- 冪等標記（掛在子元件上，見上方掃描）
            -- 重算視窗尺寸（沿原版 createChildren 尾段：取子元件最大右/下緣）
            local w, h = 0, 0
            for _, child in pairs(self:getChildren()) do
                w = math.max(w, child:getRight())
                h = math.max(h, child:getBottom())
            end
            self:setWidth(w + 11)
            self:setHeight(h + self:resizeWidgetHeight())
        end)
        if not ok then
            log("世界地圖選項面板注入圖片化開關失敗: " .. tostring(err))
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
    if not allowed then
        -- 每 tick 跑：非空才重建表，避免持續 false 期間每 tick 配置兩張空表。
        -- 空表偵測用 pairs 探測（PZ Kahlua 無 next，見 getLoadedMapDirs 註解）
        local dirty = lastAllowNavShare
        if not dirty then
            for _ in pairs(navShared) do dirty = true; break end
        end
        if not dirty then
            for _ in pairs(sharedTargets) do dirty = true; break end
        end
        if dirty then
            navShared = {}
            sharedTargets = {}
        end
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

-- 導航到達的「純狀態」判定（codex review：WM-1 早退不得連坐狀態更新）：
-- drawNavTargets 的抵達清除是狀態變更（清 modData＋分享中送 clearShared），
-- 不是繪製——世界地圖開啟期間小地圖加繪早退，但 MP 車輛乘客/外力位移仍可能
-- 在 M 開著時抵達，清除必須照跑。從繪製函式拆出，供 WM-1 早退「前」呼叫；
-- drawNavTargets 保留自己的抵達分支（正常路徑到達時同幀即清、不多等一幀）
local function navCheckArrival(inner)
    local pn = inner.playerNum or 0
    local t = navTargets[pn]
    if not t then return end
    local playerObj = getSpecificPlayer(pn)
    if not playerObj then return end
    local ddx = t.x - playerObj:getX()
    local ddy = t.y - playerObj:getY()
    if ddx * ddx + ddy * ddy <= NAV_ARRIVE_DIST * NAV_ARRIVE_DIST then
        navClear(pn, playerObj)
    end
end

-- 玩家座標列（底部置中膠囊，freelook 提示同款樣式）：一律顯示 x, y, z（與複製值
-- 一致——顯示帶空格、剪貼簿無空格，值相同；上下樓層不跳版面）；剛複製 1.5 秒內改
-- 琥珀「已複製」回饋——回饋獨立於 ShowPlayerCoords 開關（關列後 XY 鈕/右鍵複製
-- 仍看得到成功提示，否則像按鈕壞掉）；freelook 膠囊佔底行時上移一行避讓。
-- 呼叫點在 drawNavTargets 之前＝導航距離標籤畫在其上（正南目標讀數不被膠囊吃掉）
local function drawPlayerCoords(inner)
    local copied = inner._minidoracatCopiedUntil
        and getTimestampMs() < inner._minidoracatCopiedUntil
    if not (copied or getBoolOption("ShowPlayerCoords", true)) then return end
    local playerObj = getSpecificPlayer(inner.playerNum or 0)
    if not playerObj then return end
    -- 座標文字快取（perf 稽核 MISC-3）：此路徑預設恆開、每幀跑，但字串與寬度
    -- 只在玩家跨越整數格（或 copied 切換）才變——以 (ix,iy,iz) 為 key 快取，
    -- 節掉每幀的 string.format＋MeasureStringX。
    -- ⚠ x-x%1 只對非負值等於 floor：Kahlua 的 % 商先轉 int（朝零截斷，
    -- KahluaThread.java:1060），-0.2%1 得 -0.2 而非 PUC Lua 的 0.8——x/y 恆正
    -- 可用，z 在地下室樓梯上是負小數，必須走 math.floor（桌面 Lua 測試抓不到
    -- 此差異，codex review 以反編譯源實證；複製路徑也用 math.floor，兩者須一致）
    local tm = getTextManager()
    local cc = inner._minidoracatCoordCache
    if not cc then
        cc = {}
        inner._minidoracatCoordCache = cc
    end
    local txt, cw
    if copied then
        txt = getText("UI_MinidoracatMiniMap_Copied")
        if cc.copiedTxt ~= txt then
            cc.copiedTxt = txt
            cc.copiedW = tm:MeasureStringX(UIFont.Small, txt)
        end
        cw = cc.copiedW
    else
        local px, py, pz = playerObj:getX(), playerObj:getY(), playerObj:getZ()
        local ix = px - px % 1
        local iy = py - py % 1
        local iz = math.floor(pz) -- z 可為負小數（見上方 Kahlua % 註解）
        if cc.x ~= ix or cc.y ~= iy or cc.z ~= iz then
            cc.x, cc.y, cc.z = ix, iy, iz
            cc.txt = string.format("%d, %d, %d", ix, iy, iz)
            cc.w = tm:MeasureStringX(UIFont.Small, cc.txt)
        end
        txt, cw = cc.txt, cc.w
    end
    local ch = tm:getFontHeight(UIFont.Small)
    local cx = (inner.width - cw) / 2
    cx = cx - cx % 1 -- 純 Lua floor（原 math.max+math.floor 兩次跨界）
    if cx < 0 then cx = 0 end
    local cy = inner.height - ch - 10
    if inner._minidoracatFreelook and getBoolOption("FreeLook", true) then
        cy = cy - ch - 10
    end
    inner:drawRect(cx - 8, cy - 3, cw + 16, ch + 6, 0.6, 0, 0, 0)
    if copied then
        inner:drawText(txt, cx, cy, 1, 0.85, 0.4, 1, UIFont.Small)
    else
        inner:drawText(txt, cx, cy, 1, 1, 1, 0.95, UIFont.Small)
    end
end

-- 複製選定點座標到剪貼簿（右鍵選單回呼）。z 固定 0＝地面層：小地圖是平面俯視、
-- 點擊格無樓層資訊，同原版 debug 傳送 /teleportto x,y,0 慣例。回饋沿用座標列琥珀提示
function ISMiniMapInner:onMinidoracatCopyCoords(wx, wy)
    copyCoordsText(self, string.format("%d,%d,0", wx, wy))
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
        -- 複製此處座標：選項文字即時帶座標（先看到再決定點不點）
        local cwx, cwy = math.floor(worldX), math.floor(worldY)
        context:addOption(getText("UI_MinidoracatMiniMap_CopyHere",
            string.format("%d, %d, 0", cwx, cwy)), self, self.onMinidoracatCopyCoords, cwx, cwy)
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
        -- 無 PZAPI（面板不回寫）時維持舊行為：恢復為開。
        -- （置於 WM-1 早退之前：沙盒不變式須每幀維持，且引擎側小地圖 Java render
        -- 在遮蔽下照跑，本段只設引擎旗標、不繪製，順序與 zone 填色互不影響）
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
        -- perf 稽核 WM-1：世界地圖精確全螢幕（ISWorldMap.lua:1505-1506 INSET=0）且
        -- 原版從不隱藏小地圖——M 開啟期間小地圖的全部 mod 加繪 100% 被遮蔽，整段
        -- 早退（省每幀 ~50 次固定跨界＋數千次 zone 迭代＋全部繪製呼叫；取樣節流
        -- 狀態不受影響，關圖後下一幀自然恢復）。分割畫面以 playerNum 比對——他人
        -- 的世界地圖不得關掉自己小地圖的加繪（ISWorldMap.ShowWorldMap:1510 設
        -- playerNum）。已知盲點：第三方 MOD 若把世界地圖改成非全螢幕視窗，其縫隙
        -- 中小地圖暫缺 mod 疊加層（原版底圖照畫）——可接受
        if ISWorldMap_instance and ISWorldMap_instance:isVisible()
            and ISWorldMap_instance.playerNum == (self.playerNum or 0) then
            -- 早退前先跑導航到達的純狀態判定（codex review）：抵達清除是狀態
            -- 變更非繪製，MP 車輛乘客/外力位移可在 M 開著時抵達，不得連坐跳過
            pcall(navCheckArrival, self)
            return
        end
        -- Zone 填色＝mod 加繪最底層（base map 之上，安全屋/框線之下）
        safeDrawZone(self, drawZoneFill, "_minidoracatZoneFillErrLogged")
        pcall(drawSafehouses, self) -- pcall 防清單併發增刪（同殭屍取樣的防禦策略）
        pcall(drawMapBounds, self)
        safeDrawZone(self, drawZoneLines, "_minidoracatZoneLineErrLogged") -- 與 MapBounds 同層
        safeDrawZone(self, drawZoneIcons, "_minidoracatZoneIconErrLogged") -- POI 圖標，同層
        pcall(drawPlayerCoords, self) -- 在導航目標之前畫（距離標籤蓋膠囊，見函式註解）
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

-- 取消進行中的拖曳並清理捕捉旗標（小地圖在拖曳中被移除——開關快捷鍵/輪盤選單
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

-- ─── -debug 渲染除錯警告（正常遊玩零成本：非 debug 首行即返回） ───
-- Home（keycode 199）在 Core.debug 下是引擎隱藏熱鍵：IsoCell.render（IsoCell.java:3314）
-- 切換 PerformanceSettings.fboRenderChunk＝世界渲染在新 chunk-FBO 管線與舊版
-- 逐 tile 路徑間切換（FPS 砍半、積雪外觀改變）。兩種警告，前者優先：
-- 1) 已切至舊管線（fboRenderChunk=false）＝問題進行式，提示再按 HOME 復原
-- 2) 開關綁定仍是 HOME＝每次開關小地圖都同時切渲染管線，建議改鍵
-- fboRenderChunk 是 exposed class 的 public static 欄位（同 Keyboard.KEY_* 讀法），
-- pcall 防未來版本移除欄位
-- 整組收單一 local table：主 chunk 貼 Kahlua 200 locvar 上限（實測炸過），省宣告
local debugWarn = {}
function debugWarn.readFbo() return PerformanceSettings.fboRenderChunk end
function debugWarn.text()
    if not getDebug() then return nil end
    local okFbo, fbo = pcall(debugWarn.readFbo)
    if okFbo and fbo == false then
        return getText("UI_MinidoracatMiniMap_WarnLegacyRender")
    end
    if getCore():getKey("MinidoracatMiniMap_Toggle") == Keyboard.KEY_HOME then
        return getText("UI_MinidoracatMiniMap_WarnHomeBind")
    end
    return nil
end

-- 目前渲染管線狀態（-debug 才回傳，非 debug nil）：浮動圖標 tooltip 顯示用
function debugWarn.renderMode()
    if not getDebug() then return nil end
    local okFbo, fbo = pcall(debugWarn.readFbo)
    if not okFbo then return nil end
    return getText("UI_MinidoracatMiniMap_RenderMode",
        getText(fbo and "UI_MinidoracatMiniMap_RenderMode_Fbo"
            or "UI_MinidoracatMiniMap_RenderMode_Legacy"))
end

function debugWarn.draw(outer)
    local msg = debugWarn.text()
    if not msg then return end
    local fh = getTextManager():getFontHeight(UIFont.Small)
    -- 條位置：標題列（若顯示）之下、地圖內容頂部；深底＋橘字（警示色）
    local y = 0
    if outer.titleBar and outer.titleBar:isVisible() then
        y = outer.titleBar:getY() + outer.titleBar:getHeight()
    end
    outer:drawRect(0, y, outer.width, fh + 4, 0.75, 0, 0, 0)
    outer:drawTextCentre(msg, outer.width / 2, y + 2, 1, 0.62, 0.2, 1, UIFont.Small)
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

    -- 拖曳中小地圖被 Toggle 移除（開關快捷鍵/世界地圖輪盤）→ mouse up 收不到，
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
        if getBoolOption("GhostMode", false) then
            -- 穿透中：琥珀邊框＝「看得到摸不到」主提示（mod 琥珀慣例），不做 hover 變化
            self.borderColor.r, self.borderColor.g, self.borderColor.b = 1, 0.85, 0.4
        else
            local hover = self:isMouseOver() or (resizeState ~= nil and resizeState.outer == self)
            local v = hover and 0.55 or 0.4
            self.borderColor.r, self.borderColor.g, self.borderColor.b = v, v, v
        end
        originalOuterPrerender(self)
    end

    -- 角落括號＋邊緣亮條＋拖曳預覽框。掛 render：UIElement.java:1609 的 Lua render
    -- 在子元件（1604）之後呼叫，畫在整個小地圖最上層。
    local originalOuterRender = ISMiniMapOuter.render
    function ISMiniMapOuter:render()
        originalOuterRender(self)
        debugWarn.draw(self) -- -debug 專屬警告條（非 debug 一個布林即返回）
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
-- 預設 /（SLASH，M 鍵右方——大地圖 M、小地圖 /）：原版 keyBinding.lua 未綁定
-- （含裸數字掃描）、引擎 Java 層無硬編碼、本機 213 個 Workshop MOD 與 keysB42.ini
-- 全綁定掃描空閒；顯示名稱走 glfwGetKeyName＝「/」無歧義；文字輸入期間引擎不派送
-- 綁定（GameKeyboard 以 isDoingTextEntry 抑制）；scancode 按實體位置、跨佈局穩定。
-- 否決紀錄：HOME＝debug 引擎隱藏熱鍵（IsoCell.render 切換
-- PerformanceSettings.fboRenderChunk，FPS 砍半＋積雪外觀變，見 debugWarn.draw）；
-- K＝原版「Display FPS」（keyBinding.lua:199 以裸數字 37 註冊，掃 KEY_* 常數抓不到）；
-- 0＝顯示字元在 UI 字型下似字母 o（實測回饋）；F7/F8/F9＝debug 裸鍵編輯器
-- （載具/世界地圖/接縫，IngameState.java:1398/1424/1431）；F12 撞 Steam 截圖；
-- N 撞 StartVehicleEngine；9 被 Bandits Week One 事件鍵使用。
-- ToggleMiniMap 自帶防呆：沙盒未開 AllowMiniMap 時 getPlayerMiniMap 為 nil、直接略過。
local function initBinds()
    table.insert(keyBinding, { value = "[MinidoracatMiniMap]" })
    table.insert(keyBinding, { value = "MinidoracatMiniMap_Toggle", key = Keyboard.KEY_SLASH })
    -- 穿透模式預設 '（APOSTROPHE）：同規格四關驗證全空閒——引擎 Java 硬編碼
    -- （KEY_APOSTROPHE 僅常數定義、裸 40 之 isKeyDown 系 0 命中）、本機 275 個
    -- Workshop MOD 6773 個 lua 零綁定、keysB42.ini 無 key:40/altCode:40、
    -- vanilla Lua 全樹零使用；glfwGetKeyName 顯示「'」無歧義
    table.insert(keyBinding, { value = "MinidoracatMiniMap_Ghost", key = Keyboard.KEY_APOSTROPHE })
end
Events.OnGameBoot.Add(initBinds)

-- 開關小地圖（快捷鍵與浮動圖標共用入口；ponytail: 只處理 player 0，同 modOptions:apply）
local function togglePlayerMiniMap()
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

local function onKeyPressed(key)
    if key == getCore():getKey("MinidoracatMiniMap_Toggle") then
        togglePlayerMiniMap()
    elseif key ~= 0 and key == getCore():getKey("MinidoracatMiniMap_Ghost")
        and Core.toggleGhost then -- 本體在 _Ghost.lua（載入序在後），事件時查表
        Core.toggleGhost()
    end
end
Events.OnKeyPressed.Add(onKeyPressed)

-- 浮動開關圖標整節已拆至 MinidoracatMiniMap_FloatIcon.lua；
-- 一次性遷移（快捷鍵 HOME→/、大小 combobox→滑條）已拆至 MinidoracatMiniMap_Migrate.lua
-- （皆為 Kahlua locvar 上限對策；經檔尾匯出的命名空間取用主檔成員）。

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

--------------------------------------------------------------------------------
-- 跨檔命名空間匯出（供 MinidoracatMiniMap_FloatIcon/_Migrate/_Settings.lua）：
-- 皆為本檔載入期一次性賦值的穩定引用，模組檔以 local 別名共享同一實例；
-- 跨檔函式呼叫一律發生在事件/呼叫時。版本檢查（ISWorldMap.initDataAndStyle
-- 缺失）早退時不會執行到這裡→ready 不設→模組檔整組停用，與拆分前
-- 「這些區段位於版本檢查之後」同義。
--------------------------------------------------------------------------------
Core.modOptions = modOptions -- 無 PZAPI（版本過舊）時為 nil，模組沿用原 nil 檢查
Core.getBoolOption = getBoolOption
Core.getComboIndex = getComboIndex
Core.getSliderValue = getSliderValue
Core.sandboxGate = sandboxGate
Core.sandboxDist = sandboxDist
Core.displayDist = displayDist
Core.livestockVisibilityMode = livestockVisibilityMode
Core.unifiedCsvSet = unifiedCsvSet
Core.ADOTS_COLOR_ITEMS = ADOTS_COLOR_ITEMS
Core.ADOTS_SPECIES_UI = ADOTS_SPECIES_UI
Core.ADOTS_VEHCAT_UI = ADOTS_VEHCAT_UI
Core.ADOTS_ART = ADOTS_ART
Core.adotsTexture = adotsTexture
Core.registeredPacks = registeredPacks
Core.registeredZoneProviders = registeredZoneProviders
Core.hasExternalZoneProvider = hasExternalZoneProvider
Core.registeredZoneActions = registeredZoneActions
Core.togglePlayerMiniMap = togglePlayerMiniMap
Core.debugWarn = debugWarn
Core.applyChromeOpacity = applyChromeOpacity -- _Ghost.lua 切換穿透時重套外框透明度
Core.cancelResize = cancelResize -- _Ghost.lua 進穿透時取消進行中的邊緣縮放
Core.ready = true -- 模組檔載入閘門：最後設定＝主檔完整走完才放行

log("已載入（hook ISWorldMap:initDataAndStyle + ISMiniMap.InitPlayer + 按鈕列模式 + 齒輪面板 + 快捷鍵 + MOD 選項 + 殭屍點位 + 邊緣縮放）")
