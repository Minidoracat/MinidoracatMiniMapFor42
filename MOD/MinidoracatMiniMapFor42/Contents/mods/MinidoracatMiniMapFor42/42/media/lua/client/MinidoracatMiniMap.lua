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
--   繪製對層列「正序」迭代（WorldMapRenderer.renderCellFeatures，:933-938——
--   :920-926 的 renderVisibleCells 是層「內」的 cell 迴圈，勿混）——後建的層畫在上面，
--   故基底層先建（最底）、addon 層後建（最上）。每顆 zip 自帶 bounds 自動對位。
--   注意：同一層內的同名多 zip（多個第三方 addon）引擎是「反序」迭代
--   （WorldMapPyramidStyleLayer.java:46-51），先註冊者畫在上面。

local OWN_MOD_ID = "MinidoracatMiniMapFor42" -- 同 mod.info 的 id

-- 跨檔命名空間（單一全域）：主檔拆分為 MinidoracatMiniMap_*.lua 模組檔
-- （_Dots/_FloatIcon/_Ghost/_Migrate/_NavRoute/_Search/_Settings/_Zones 等）——Kahlua 編譯器每個函式原型（含每檔主 chunk）locvar 上限 200
-- （LexState.new_localvar 固定陣列，超過＝整檔拒載、MOD 全滅），單檔主 chunk 曾貼頂，
-- 拆檔＝每檔獨立額度。共用成員於檔尾一次匯出（含 ready 閘門）；PZ 依字母序載入
-- 同目錄檔案（'.' 0x2E < '_' 0x5F），本檔必先載、模組檔載入時命名空間已就緒。
local Core = {}
MinidoracatMiniMapCore = Core

-- 本 MOD 自帶圖檔 manifest：zip＝media/minimap/ 下檔名；mapMod 省略＝基底、永遠掛載，
-- 指定時＝該地圖 MOD 的 mod ID，啟用才掛載。支援新地圖：pzmap Studio 渲染出
-- <地圖名>.pyramid.zip（預設輸出名，免改名）丟進 media/minimap/，在此加一行即可。
-- sortable=false＝該條目完全不吃疊層優先序重排（見 orderByMapPriority）：基底是
-- 全世界底圖、語意上恆在最底，不能因為「剛好有地圖 MOD 把資料夾命名成 Muldraugh_KY」
-- 就被優先序搬到 MOD 地圖上面（zip basename 撞名，同 legacy 的隱含隔離破功，
-- code review 抓出）。PZ 不禁止這個資料夾名，靠「對不上目錄」隔離只是巧合
-- 第三方 addon 相容約定檔名（零 Lua）：地圖 MOD 自附 minimap 支援時使用
local LEGACY_CANONICAL = "minidoracat_minimap.pyramid.zip"
-- test:maps:start
local MAPS = {
    { zip = "Muldraugh_KY.pyramid.zip", sortable = false }, -- 基底全圖（B42 主世界）
}
-- test:maps:end

-- MOD 地圖包註冊 API（地圖包 addon 專用，如 MinidoracatMiniMapModMapsFor42）：
-- 地圖包在自己的 client lua 呼叫（mod.info require=本 MOD 保證本檔先載入）：
--   MinidoracatMiniMapAPI.registerMaps("<地圖包自身 mod ID>", {
--       { zip = "<地圖名>.pyramid.zip", mapMod = "<該地圖 MOD 的 mod ID>",
--         bounds = { x1, y1, x2, y2 }, nameKey = "UI_..." }, ...
--   })
-- zip 放地圖包自己的 media/minimap/；bounds＝渲染時 pyramid.txt 的世界 square
-- 座標（右/下排他，cell*256，MinidoracatMapRendering/src/pyramid.rs:179-186）；
-- nameKey 缺譯退 mapMod。同地圖多 mod ID 變體＝同 zip/bounds 多條目（掛載去重）。
-- 選配 mapDir＝該條目的地圖目錄名（media/maps/ 下資料夾）。它有兩個獨立作用，別混：
-- (1) 掛載閘門（passesMapDir，在蒐集前就判）：MP 伺服器 Map= 沒載入該目錄就不掛載
--     也不畫框。省略＝不設閘門、一律放行——伺服器只挑部分地圖時，未載入的那張仍會
--     被畫出（回報實例：未載入的 SecretZ 據點）。下面的 identity fallback 只補排序，
--     救不了這條，所以要避免「未載入卻被畫出」就得明寫，單地圖 mod 也一樣。
-- (2) 疊層優先序的 identity：省略時先試 zip basename，不符再用 getMapFoldersForMod
--     反查。一個 mod 內含多張地圖（如 SecretZ 12 據點）時反查會因歸屬含糊而放棄，
--     該條目就吃不到優先序——這種 mod **必須**指定。
-- zip 不可用 LEGACY_CANONICAL（minidoracat_minimap.pyramid.zip）：那是「零 Lua 自動
-- 掃描」lane 的保留名，同名兩份條目會互搶同一圖層並打亂固定位置，本 API 直接拒收該條目。
local registeredPacks = {} -- { { owner = <地圖包 mod ID>, entries = {...} }, ... }
MinidoracatMiniMapAPI = MinidoracatMiniMapAPI or {}
-- test:register-maps:start
function MinidoracatMiniMapAPI.registerMaps(ownerModId, entries)
    if type(ownerModId) ~= "string" or ownerModId == "" or type(entries) ~= "table" then
        print("[MinidoracatMiniMap] registerMaps: bad arguments (need ownerModId, entries)")
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
            and (e.streetI18n == nil or type(e.streetI18n) == "string")
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
        if ok and e.zip == LEGACY_CANONICAL then
            -- 保留名：canonical 檔名專屬「零 Lua 自動掃描」那條 lane。兩條 lane 同時
            -- 產出同檔名條目時，registerMaps 那份較早被蒐集、會吃疊層優先序被搬走，
            -- 而 mountPyramidLayers 又以第一個同 layerId 為準去重，等於把固定在尾端的
            -- legacy 那份丟掉——canonical 層可能被壓到其他地圖層下面（codex review 以
            -- probe 重現）。用 canonical 名的 addon 本來就不必呼叫本 API，單點拒收
            print("[MinidoracatMiniMap] registerMaps: entry #" .. i .. " from " .. ownerModId
                .. " uses the reserved auto-scan filename " .. LEGACY_CANONICAL
                .. " -- skipped (rename the zip to the map folder name and register that)")
        elseif ok then
            table.insert(valid, e)
        else
            print("[MinidoracatMiniMap] registerMaps: skipping invalid entry #" .. i .. " (from " .. ownerModId .. ")")
        end
    end
    if #valid > 0 then -- 空包不註冊：地圖包選項不該因空資料出現
        table.insert(registeredPacks, { owner = ownerModId, entries = valid })
    end
end
-- test:register-maps:end

-- Zone 渲染 API（家族第四個 addon＝MinidoracatMiniMapZonesFor42 的資料層專用）：
-- 資料 addon 註冊 provider，本 MOD 每幀呼叫取回「已翻譯、已正規化」的 zone 陣列，
-- 在小地圖與世界地圖填半透明色＋畫框線＋標名稱。zoneApiVersion 供 addon 掛載前守衛
-- 版本（契約 C1）——舊主 MOD 無此欄位／無 registerZoneProvider，addon 應安靜降級。
-- provider 契約（C2）：providerFn 每幀被呼叫（世界＋小地圖），必須回傳「快取 table」、
-- 勿每幀重建/過濾/合併；本 MOD 對回傳只讀不改。zones 必須是**連續陣列**（1..n 無
-- nil 洞）——渲染端與候選快取都以 `#` 遍歷；移除元素用 table.remove（緊縮）。
-- `zones[i]=nil` 挖洞屬違約輸入：本 MOD 保證不拋錯（sentinel／nil guard），但 `#`
-- 對有洞的表未定義，洞後項目可能整段不掃（＝漏畫，且此語意快取前即如此）。
-- zone schema（provider 產、繪製端讀）：
--   { id=string, name=string|nil(已翻譯顯示名；nil＝不畫名稱),
--     rects={ { x1=, y1=, x2=, y2= }, ... }(世界 square 座標；硬性要求 x1<x2、y1<y2——
--       三個 pass 的視野預裁都假設此序，反向 rect 會被一致地過嚴裁掉而整個消失),
--     fill={ r=, g=, b= }(0-1), fillAlpha=number(0＝不填),
--     border={ r=, g=, b= }(0-1), borderAlpha=number(0 或缺 border＝不畫框；
--       ⚠ 不影響 name——兩者自 2026-08-13 解耦，純色塊＋名稱是合法組合),
--     haloAlpha=number|nil(選配；>0＝fill pass 在每 rect 填色下先畫外擴 2px
--       的黑色底襯 quad——無框線區塊的暗色描邊，每 rect 僅 1 次 drawPolygon
--       （stencil 裁切、零 Lua 裁線），遠低於 4 條框線的成本。檔位：帶 lodRect
--       的 zone 僅細節檔畫（中距/拉遠不畫，城市尺度熱點零新增）；無 lodRect
--       的 zone（恆顯的大範圍區域/地標）全檔位畫——描邊跟著填色走，0.14.1 起，
--       見 fill pass 檔位註解。POI 區塊模式用；無此欄位行為不變),
--     icon={ tex=<Texture>, r=, g=, b= }|nil(選配；每 rect 中心畫染色圖標),
--     iconOnce=true|nil(選配；true 時圖標只畫在 rects[1]——provider 應把主要
--       矩形排在首位；名稱本就恆只錨定 rects[1]、與此旗標無關。未設維持
--       每 rect 一圖標，既有 addon 行為不變),
--     iconRect={ x1=, y1=, x2=, y2= }|nil(選配；覆寫第一顆圖標的錨定矩形，
--       不影響 fill/line/名稱。POI 整棟外框模式用：框畫整棟、圖標仍釘在
--       最大房間。四欄不齊者忽略、回退 rects[1]),
--     distRects={ {x1=,y1=,x2=,y2=},.. }|nil(選配；覆寫顯示距離閘的量測對象，
--       預設量 rects。POI 整棟外框模式用：畫整棟框但距離仍由分類房間決定，
--       使該開關純屬外觀、不改變可見距離。不要求含於 lodRect——有給時距離
--       判定不用 lodRect 快排，逐矩形直判),
--   ⚠ 註冊時機：provider 應於 OnGameBoot 前註冊（檔案載入期，family addon 慣例）
--     ——ZoneLayer/ZoneNames/ZoneNamesFar/ZoneCategoryFilter/ClientZoneDisplayDistance 選項
--     與地圖顯示設定的「自訂區域」分類、「顯示距離」分類第 6 條滑條都在 OnGameBoot 依
--     「有無外部 provider」一次性建立。之後才註冊者仍會被渲染（fail-visible：
--     名稱總閘／遠距與玩家距離依預設值生效；沙盒 ZoneDisplayDistance 仍照裁），
--     但本場沒有對應 UI 可調。
--   zones「表本身」可帶選配聚合旗標 hasFill/hasLine/hasIcon（ZR-1）：false＝
--     provider 聲明該 pass 無任何可畫內容，renderer 整段跳過迴圈（內建 POI 預設
--     純圖標模式靠此免去 fill/lines 每幀空掃全部 zone）；nil＝未聲明，照舊逐
--     zone 判斷——外部 addon 不設即行為不變。旗標須與內容同步重建（錯設漏畫是
--     provider 的 bug）。
--     lodRect={ x1=, y1=, x2=, y2= }|nil(選配；**必須涵蓋該 zone 全部 rects**
--       （涵蓋框；0.16.0 起候選快取於所有檔位依它裁切，先前僅 LOD 檔位——
--       過小的 lodRect 會讓 zone 在細節檔整個消失）。有給＝參與縮放 LOD——
--       worldScale < ZONE_LOD_HIDE 時 fill 整區不畫、< ZONE_LOD_DETAIL 時
--       fill 只畫此聯集框（純填色，框線與名稱僅細節檔）、圖標於 < DETAIL 時
--       做同格去重疊（同一「圖標尺寸」螢幕格只畫第一顆，細節檔全畫）。
--       未設＝一律畫全部 rects、圖標不去重疊，既有 addon 行為不變),
--     category=string|nil }
-- 選配第三參 optionLabelKey：有給時本 MOD 於統一視窗動態追加一顆 per-provider 母開關，
-- 關＝渲染時整個跳過該 provider；與 ZoneLayer 總開關是 AND 關係（皆開才畫）。
-- 單一外部 provider 時母開關與總開關作用範圍 100% 重疊——家族 Zones addon 自其
-- 0.5.0 起不再傳此參（兩顆相鄰等效開關令人困惑，實測回饋）；機制保留給第三方／
-- 未來多 addon。⚠ 主 MOD 端勿以「provider 數」動態隱藏已註冊的母開關——會產生
-- 雙向幽靈（玩家關過的 ini 值被靜默翻回顯示、日後第二個 addon 裝上時又復活——
-- codex review 裁決）；要不要母開關由 addon 端「傳或不傳」靜態決定。
-- 選配第四參 internal：true＝本體內部 provider（如內建 POI），不受 ZoneLayer 總閘連坐、
-- 由自家開關（PoiIcons/PoiBlocks/類別）控制；外部 addon 一律省略（受 ZoneLayer 總閘）。
-- ⚠ 傳 internal 者受 POI 顯示距離閘（沙盒 PoiDisplayDistance/AllInfoDistance＋
-- 玩家自訂距離）連坐；外部 provider 另受自訂區域顯示距離閘（沙盒
-- ZoneDisplayDistance/AllInfoDistance＋玩家 ClientZoneDisplayDistance，預設 0＝
-- 不裁）——任一距離閘啟用時 zone 依玩家距離被靜默裁掉（fill/框線/名稱/圖標
-- 一致顯隱），addon 勿依賴「恆全圖可見」。
local registeredZoneProviders = {} -- { { owner=, fn=, optionLabelKey=, optionKey=, internal= }, ... }
-- ZoneLayer 總開關的 UI 出現條件＝「有『外部』provider」：內建 POI（internal=true）
-- 繞過 ZoneLayer 閘門（見 drawZoneFill/Lines/Icons 的 gating），若把 internal 也計入，
-- 純本體安裝會出現一顆對任何東西都無作用的死開關（codex review 抓出）。
-- test:has-external-provider:start
local function hasExternalZoneProvider()
    for i = 1, #registeredZoneProviders do
        if not registeredZoneProviders[i].internal then return true end
    end
    return false
end
-- test:has-external-provider:end
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
-- 主 MOD 於自訂區域 tick 之後渲染 [combo]+[按鈕]（options 有給才有 combo）；按鈕點擊呼叫
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

-- 排序 identity 的權威解析（zip 名對不上時的補救）：問引擎「這個地圖 MOD 提供哪些
-- 地圖資料夾」，取其中已載入的那個。zip 檔名是給人看的別名，未必等於地圖資料夾名
-- ——實測地圖包 91 筆有 3 筆不等（Atlanta - Safe Zone 的目錄帶社群後綴、EchoCreek
-- 目錄夾中文、Kardinal Raven Creek 的目錄其實叫 Raven Creek B42），其中 Atlanta 與
-- EdsAutoSalvageB42 真的共用 3 格 cell，光靠 zip 名會讓它排不進優先序、繼續被壓在下面
-- （codex review 抓出的正式資料反例）。
-- getMapFoldersForMod(modID)：掃該 mod 的 commonDir＋versionDir 下 media/maps/*/map.info
-- 回資料夾名 ArrayList，找不到回 nil、例外自行 catch（LuaManager.java:5390-5445；
-- 用例 ServerSettingsScreen.lua:1127/1168/2303）——與 MapGroups 建 realDirectories 的
-- 掃描範圍一致（MapGroups.java:116／:130），故不必自己組路徑。
-- 只在「該 mod 總共只提供一張地圖」時才反推：mod ID → 資料夾是多對一，
-- getMapFoldersForMod 給的是資料夾清單、沒有 zip→資料夾的關聯（LuaManager.java:5394）。
-- 拿「當下只有一個已載入」當識別會出錯：mod 提供 A、B 而 registry 的 B.pyramid.zip
-- 省略 mapDir、MP 只載入 A 時，會把 B 的影像標成 A 的 identity、吃 A 的優先序
-- （codex review 抓出）。多張一律回 nil，該由 registry 明寫 mapDir。
-- 同名資料夾在 common 與版本目錄各回一次（Java 兩段各自 add），比的是名稱、不算多張
-- test:resolve-mapdir:start
local function resolveMapDirByMod(modID, loadedDirs)
    local folders = getMapFoldersForMod(modID)
    if folders == nil then return nil end
    local only
    for i = 1, folders:size() do
        local dir = folders:get(i - 1)
        if only == nil then
            only = dir
        elseif only ~= dir then
            return nil -- 一 mod 多地圖：無法從 mod ID 反推這顆 zip 是哪張
        end
    end
    -- 該地圖沒在載入清單裡＝這顆 zip 不該吃優先序（MP Map= 沒挑到它）
    if only == nil or loadedDirs[only] == nil then return nil end
    return only
end
-- test:resolve-mapdir:end

-- 一 mod 多地圖（SecretZ 類）的逐圖閘門：MP 伺服器可在 Map= 只挑部分地圖目錄
-- 載入，mod ID 閘門看不出這層差異（回報實例：未載入的 SecretZ 據點仍被畫出）。
-- getWorld():getMap()（Java Core.gameMap）＝實際載入地圖目錄的分號串列——單機為
-- MapGroups 串起的全部啟用 MOD 目錄、MP 客戶端為伺服器 Map= 清單（世界 init 時
-- IsoMetaGrid.getLotDirectories 回填；42.19 反編譯查證），兩種模式皆可信。
-- 約束：僅供世界 init 之後呼叫（連線早期 Core.gameMap 短暫只有首項）——現有
-- 呼叫點（applyMiniMapPyramids 各觸發源；_NavRoute.lua makeWinnerOf——設目標
-- 後首個繪製幀啟動，必在世界 init 後）皆滿足；新增更早呼叫點前先想這條。
-- 回傳 dir → 優先序 index（1＝最高，同名 cell 覆蓋其後所有目錄——見 orderByMapPriority）；
-- nil＝拿不到（fail-open）。值刻意用 index 而非 true：疊層順序要靠它（0.14.3 前只存集合）
-- test:mapdir-gate:start
local function getLoadedMapDirs()
    local okCall, mapStr = pcall(function()
        local world = getWorld()
        return world and world:getMap() or nil
    end)
    if not okCall then
        -- 只有「真的拋例外」才留痕：getWorld/getMap 綁定失效是靜默症狀最貴的一種
        -- ——fail-open 會讓 mapDir 閘門放寬＋疊層不重排（＝疊層錯序 bug 復活），
        -- 沒有這行就查不出來。DEFAULT／空串維持靜默：那是世界未 init 的正常路徑，
        -- 本函式在每次開圖／樣式重建都跑，無條件 log 會刷屏。一次 apply 會呼叫兩次
        -- （rebuildMapOverlays 與 collectPyramids 各一），例外時就是兩行——例外屬綁定
        -- 失效等罕見狀況，重複兩行比為了去重而把 loadedDirs 穿過兩層簽名划算
        log("getLoadedMapDirs: getWorld():getMap() raised, falling back to mod ID gate only "
            .. "(no priority reorder): " .. tostring(mapStr))
        return nil
    end
    if type(mapStr) ~= "string" or mapStr == "" or mapStr == "DEFAULT" then
        return nil -- 拿不到＝fail-open：mapDir 閘門放寬，且 orderByMapPriority 不重排
    end
    local dirs, count = {}, 0
    for dir in string.gmatch(mapStr, "[^;]+") do
        dir = dir:match("^%s*(.-)%s*$")
        -- 首見才記：重複目錄不該改寫已定的優先序（引擎同樣去重，
        -- IsoMetaGrid.java:2017 的 result.contains 守衛）
        if dir ~= "" and dirs[dir] == nil then
            count = count + 1
            dirs[dir] = count
        end
    end
    -- 空表偵測用計數器：PZ Kahlua 無 next（BaseLib.java 僅註冊 18 個全域、TableLib
    -- 只有 pairs/ipairs），0.10.0 曾用 next 導致實機掛載鏈全炸（離線測試跑標準 Lua 沒抓到）
    if count > 0 then return dirs end
    return nil -- 拆完是空集＝同「拿不到」，fail-open
end

-- 條目沒指定 mapDir、或載入清單拿不到＝通過；指定了就要求該目錄真的載入。
-- 空字串視同未指定（codex review：validator 放行 ""，但 "" 永遠匹配不到——
-- 單點中和、不整條目拒收，壞欄位只降級回 mod ID 閘門）
local function passesMapDir(entry, loadedDirs)
    return entry.mapDir == nil or entry.mapDir == ""
        or loadedDirs == nil or loadedDirs[entry.mapDir] ~= nil
end
-- test:mapdir-gate:end

-- 純決策（離線測試 scripts/test_mapdir_gate.lua）：待掛載清單依「引擎地圖優先序」
-- 重排。同一 cell 被多個地圖 MOD 提供時引擎只載入優先序最前那份（CreateStep1 對
-- MapFiles 反序 putAll，IsoMetaGrid.java:1424-1428；原版註解 "Add data from highest
-- priority (mods) to lowest priority (vanilla)"，ISMapDefinitions.lua:25-28）——影像層
-- 必須跟隨同一個勝出者，否則會拿「輸的那張」蓋掉玩家實際所在的地圖。
-- 回報實例：Grapeseed 北緣 3 cell 與 Greenleaf 重疊（兩者 pyramid 該帶皆不透明），
-- 舊的 registry 字母序讓 Greenleaf 的空草地蓋掉 Grapeseed 城區（2026-08-17 地圖包留言）。
-- 層間繪製正序、後建在上（WorldMapRenderer.renderCellFeatures，:933-938）⇒ 依 pri 遞減
-- 建層＝優先序最高者最後建、畫最上。
-- 注意這只讓影像與世界一致，重疊 cell 本身仍是引擎層級的硬衝突
-- （MapGroups.checkMapConflicts，MapGroups.java:476-514），兩張圖不可能同時完整顯示。
-- 只重排「對得上已載入目錄」的條目（identity 由 collectPyramids 先補齊：registry 的
-- mapDir → zip basename → resolveMapDirByMod）並就地填回其原位置；identity 對不上的
-- 條目維持原槽。
-- 但「對不上」不是位置保證：sortable == false 才是。基底全圖與 legacy 約定名 addon
-- 都必須固定位置（前者恆在最底、後者恆在最上），而它們的 zip basename
-- （Muldraugh_KY／minidoracat_minimap）若剛好撞到某個合法地圖目錄名，就會被解析成功
-- 並被優先序搬走——PZ 不禁止這兩個資料夾名，故一律用顯式旗標釘住（codex review
-- 第三輪抓出 legacy、code review 抓出基底）。
-- 已知邊界（刻意不處理）：本函式只管「層間」順序。同一個 zip 檔名的多個條目會被
-- mountPyramidLayers 去重成一層，該層以尾綴匹配畫出所有同名 zip、且是層「內」反序
-- （先 addImagePyramid 者在上）——若同名條目來自不同路徑，本函式排出的層間順序反而
-- 會讓低優先者先掛而畫在上面（codex review 第五輪以 probe 指出）。不修的理由：
-- (1) 唯一真實存在的同名多路徑情境是 legacy 那條 lane（多個 addon 共用 canonical
-- 檔名、各自 bounds 對位，是刻意設計），而它已 sortable=false、順序等同本次修改前；
-- (2) 兩個地圖包 addon 提供同名 zip 時，兩份影像可能都合法且不重疊，「誰該在上」本來
-- 就沒有定義，去重會直接弄丟一張圖；(3) 真要支援得按檔名分組反轉該組註冊序，不是
-- 丟資料。等實際生態出現再做
-- test:map-priority:start
local function orderByMapPriority(entries, loadedDirs)
    if loadedDirs == nil then return entries end
    local slots, known = {}, {}
    for i = 1, #entries do
        local e = entries[i]
        local dir = e.mapDir
        if dir == nil or dir == "" then
            dir = e.zip:gsub("%.pyramid%.zip$", "")
        end
        local pri = e.sortable ~= false and loadedDirs[dir] or nil
        if pri then
            slots[#slots + 1] = i
            -- 插入排序（家規：Kahlua 禁用 table.sort，見 verify_mod.py）：pri 遞減，
            -- 嚴格 < 才位移＝相等保留原序（穩定）。n＝已啟用地圖數（實測上限約百筆）；
            -- 只在掛載流程跑（開世界地圖／小地圖 init／樣式重掛），不在每幀路徑上
            local pos = #known + 1
            while pos > 1 and known[pos - 1].pri < pri do
                known[pos] = known[pos - 1]
                pos = pos - 1
            end
            known[pos] = { entry = e, pri = pri }
        end
    end
    for k = 1, #slots do
        entries[slots[k]] = known[k].entry
    end
    return entries
end
-- test:map-priority:end

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

-- 回傳待掛載清單 { { path=絕對路徑, zip=檔名, mapMod=地圖 mod ID 或 nil,
-- mapDir=地圖目錄名或 nil, sortable=false 才不吃優先序重排 }, ... }：
-- 蒐集序＝MAPS 再地圖包再 legacy addon，
-- 補齊排序 identity 後由 orderByMapPriority 依引擎地圖優先序重排
-- （applyMiniMapPyramids 依序建層、後建在上）
-- test:collect-pyramids:start
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
                    table.insert(list, { path = path, zip = entry.zip, mapMod = entry.mapMod,
                        mapDir = entry.mapDir, sortable = entry.sortable })
                elseif not entry.mapMod then
                    log("base map zip missing: " .. entry.zip .. " (not rendered yet? expected under 42/media/minimap/, see scripts/build_pyramids.ps1)")
                else
                    log("map mod " .. entry.mapMod .. " is enabled but the pack is missing " .. entry.zip .. " (not rendered or not packaged?)")
                end
            end
        end
    else
        log("getModInfoByID(\"" .. OWN_MOD_ID .. "\") returned nil -- OWN_MOD_ID mismatch with mod.info id? all manifest layers disabled")
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
                            table.insert(list, { path = path, zip = entry.zip,
                                mapMod = entry.mapMod, mapDir = entry.mapDir })
                        else
                            log("map pack " .. pack.owner .. " missing " .. entry.zip .. " (not rendered or not packaged?)")
                        end
                    end
                end
            else
                log("invalid map pack mod ID: " .. tostring(pack.owner) .. " (registerMaps first argument must be the pack own mod ID)")
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
                    -- sortable = false＝完全不吃優先序重排（顯式，不靠「沒有 mapMod」
                    -- 或檔名巧合）：legacy 全體共用同一檔名，去重後只有一層，它們的
                    -- 上下由 addImagePyramid 呼叫序決定，而層「內」同名多 zip 是反序
                    -- 迭代（WorldMapPyramidStyleLayer.java:46-51）＝先註冊者畫在上，
                    -- 與層「間」的後建在上相反。把層間規則（低優先先掛）套進來會讓
                    -- 低優先者反而蓋住高優先者（codex review 抓出）。要支援得改成按
                    -- 檔名分組反轉註冊序，收益不值這風險
                    table.insert(list, { path = path, zip = LEGACY_CANONICAL, sortable = false })
                end
            end
        end
    end
    -- 補齊排序 identity：zip 名對不上已載入目錄時，用 getMapFoldersForMod 反查。
    -- 只對「有 mod ID 可問」的條目做——基底與 legacy 都沒有 mapMod，不需要 identity
    -- （它們的位置由 sortable=false 釘住，不是靠這裡跳過）。只跑對不上的少數條目
    -- （正式資料 3 筆）、每筆一次 Java 目錄掃描；與排序同頻（每次地圖初始化／樣式
    -- 重掛），成本可忽略
    if loadedDirs ~= nil then
        for _, e in ipairs(list) do
            if (e.mapDir == nil or e.mapDir == "") and e.mapMod ~= nil
                and loadedDirs[e.zip:gsub("%.pyramid%.zip$", "")] == nil then
                e.mapDir = resolveMapDirByMod(e.mapMod, loadedDirs)
                if e.mapDir == nil then
                    -- 真資料缺口：有 mod ID，卻既對不上 zip 名、也反查不到唯一目錄
                    -- ⇒ 該層不吃優先序，重疊時可能顯示錯的地圖，registry 該補 mapDir。
                    -- 只有這種條目會 log（正式資料應為 0 筆）：基底與無 mapMod 的
                    -- 條目不進這裡，不會每次開圖刷屏
                    log("cannot resolve map directory for " .. e.zip .. " (mod " .. e.mapMod
                        .. ") -- layer stays unsorted; add an explicit mapDir in the registry")
                end
            end
        end
    end
    return orderByMapPriority(list, loadedDirs)
end
-- test:collect-pyramids:end

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
    if not layersNeedRebuild(indices, styleAPI:getLayerCount()) then return false end

    if existed > 0 then
        -- 自癒證據行「先印再動手」（中途失敗仍留診斷）＋指認當前最上層（壓層
        -- 兇手或亂序訊號）：玩家回報「藍色遮蓋」類問題時，console.txt 有此行
        -- ＝命中圖層順序窗口，最上層 id 直接指出來源
        local top = styleAPI:getLayerByIndex(styleAPI:getLayerCount() - 1)
        log("layer self-heal: our layers no longer occupy the style tail contiguously (found " .. existed .. " / expected "
            .. #layerIds .. "; current top layer id=" .. tostring(top and top:getID()) .. "), remounting all")
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
                log("mounted pyramid: " .. e.path)
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
        log("layers ready (added " .. added .. " / " .. #layerIds .. " pyramid layers total)")
    end
    return true -- 有拆掛重建（呼叫端據此失效穿透壓暗快照——重建層以全 alpha 掛回）
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
        log("no pyramid zip found, no layers added")
        return
    end

    -- 掛載 zip（Java 側 WorldMap.addImagePyramid 自帶去重，重開地圖重複呼叫安全）
    for _, e in ipairs(entries) do
        mapAPI:addImagePyramid(e.path)
    end

    -- 樣式層：疊在原版樣式之上，不清空原版（刻意不學 showTerrainImage 的
    -- styleAPI:clear()）。掛載/自癒細節見 mountPyramidLayers
    local rebuilt = mountPyramidLayers(styleAPI, entries)
    -- 穿透壓暗快照失效（防禦性前置條件，_Ghost.lua alphaUsed sentinel 契約）：拆掛
    -- 重建的層以全 alpha 掛回，dim 的同值冪等檢查（alphaUsed==滑條值）會誤判「已壓
    -- 過」而跳過重壓。**目前無活路徑**（三 lane review 呼叫點窮舉）：世界地圖單例
    -- 從不被 dim＝永無快照；InitPlayer 的 inner 在 applyGhost（其後才跑）前必無快照；
    -- Recreate＝整個 inner 換新、快照隨舊件消失。留著防未來新增「對既有 inner 原地
    -- 重掛」的路徑時穿透靜默回歸（成本＝兩行）。快照鍵＝layer:getID()，重建層同
    -- id、還原寫回重建前原值（255）＝no-op
    if rebuilt and mapUI._minidoracatGhostSnap then
        mapUI._minidoracatGhostSnap.alphaUsed = nil
    end

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

-- 政策 facade（全域 MinidoracatMiniMapPolicy，shared/ 於檔尾發布）：Java
-- SandboxOptions 為真相源（含 250ms 快取），並負責「管理員個人旁路」的白名單
-- 裁決。shared 目錄先於 client 載入（LuaManager.java:1243-1246
-- LoadDirBase("shared")→LoadDirBase("client")），故載入期取到的即完整表。
-- 缺席（舊版共用檔／載入失敗）＝下方全部讀取退回既有 SandboxVars 直讀，
-- 管理員旁路整組不存在＝fail closed。
local Policy = MinidoracatMiniMapPolicy

-- 沙盒管理閘門（media/sandbox-options.txt 定義）：客戶端每幀讀值——
-- 管理員沙盒面板改動同步後即時生效；缺表/缺鍵時回呼叫端提供的 default。
-- pn＝這次要判定的顯示對象（分割畫面各自判定，不得借 player 0 的權限）：
-- 戰術白名單鍵在該玩家的管理員戰術檢視生效時由 Policy 回 true。白名單外
-- （AllowNavShare／Export*／全部 AutoDrive gameplay）永不旁路，傳不傳 pn
-- 結果都一樣——那些呼叫點刻意「不傳 pn」以在程式碼上表明不旁路。
local function sandboxGate(name, default, pn)
    if Policy then return Policy.gate(name, default, pn) end
    local sb = SandboxVars and SandboxVars.MinidoracatMiniMap
    local v = sb and sb[name]
    if v == nil then return default end
    return v
end

-- 距離沙盒值 0 或缺值＝不限制；僅正數啟用距離閘門。AllInfoDistance＝全域距離
-- 上限（最優先）：與個別距離取較小的正值——個別值只能更嚴、不能放寬全域上限；
-- 只設全域時全部距離項目（殭屍/動物/載具/安全屋/POI/自訂區域）一體生效。
-- 戰術檢視生效時 Policy 對白名單距離鍵回 nil（不限制）＝旁路伺服器上限；
-- 玩家自訂滑條仍在 displayDist 收緊（旁路只解伺服器閘，不解自己的偏好）
-- test:sandbox-distance:start
local function sandboxDist(name, pn)
    if Policy then return Policy.sandboxDistance(name, pn) end
    local v = sandboxGate(name, 0)
    if type(v) ~= "number" or v <= 0 then v = nil end
    local g = sandboxGate("AllInfoDistance", 0)
    if type(g) == "number" and g > 0 and (not v or g < v) then return g end
    return v
end
-- test:sandbox-distance:end

-- 牲畜可見性：1=全部、2=隱藏其他安全屋內、3=僅我方安全屋內、4=全部隱藏。
-- 單機沒有可用的玩家間安全屋歸屬語意，前 3 檔等同全部顯示；第 4 檔仍有效。
-- 隱私檢視生效時 Policy 回 1（取最寬模式）；單機收斂亦由 Policy 內處理
-- test:livestock-effective-mode:start
local function livestockVisibilityMode(pn)
    if Policy then return Policy.livestockMode(pn) end
    local mode = sandboxGate("LivestockVisibility", 2)
    if type(mode) ~= "number" or mode < 1 or mode > 4 then mode = 2 end
    if not isClient() and mode ~= 4 then return 1 end
    return mode
end
-- test:livestock-effective-mode:end

-- 安全屋範圍顯示模式：1=關閉、2=僅自己所屬、3=全部（預設；缺表視為 3）。
-- 隱私檢視生效時 Policy 回 3（取最寬模式，與距離閘一併放行）
local function safehouseDisplayMode(pn)
    if Policy then return Policy.safehouseMode(pn) end
    return sandboxGate("SafehouseDisplay", 3)
end

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
-- 併全域上限 AllInfoDistance，並套管理員戰術旁路）與玩家自訂值（Client<沙盒
-- 選項名>，ESC 頁與統一視窗「顯示距離」區同一滑條）取較小正值——玩家只能
-- 收緊、不能放寬伺服器閘；0/缺值＝該層不限制。
-- pn＝顯示對象（分割畫面各自判定）；管理員旁路把 server 端拿掉後，玩家自己
-- 的 Client* 滑條照舊生效（旁路不解自己的偏好）
-- test:display-distance:start
local CLIENT_DIST_MAX = 2000 -- 客戶端滑條值域上限（ESC 頁/統一視窗/夾限同值）
local function displayDist(name, pn)
    local server = sandboxDist(name, pn)
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


-- 沙盒 MapAllKnown（開始時全部已知）的 42.20.3 補位：MP 的 all-known 原由
-- PlayerVisitedPacket 在收完 visited 同步後 setKnownInCells 全圖實現
-- （42.20.2 PlayerVisitedPacket.java:66-68），42.20.3 該封包被移除、僅剩 SP 的
-- WorldMapVisited.load 路徑（42.20.3 WorldMapVisited.java:892-895）——MP 下
-- 沙盒開了也不再全圖（引擎回歸，實測 servertest MapAllKnown=true 失效）。
-- 補位：client 端關 HideUnvisited（引擎鏈 UIWorldMap.java:183-186 →
-- setVisited(null)＝未探索遮罩整層不畫、pyramid 影像全示）。伺服器沙盒明示
-- 全開＝無「穿透求透明」條目的洩漏疑慮；官方日後修回＝冪等重設無害。
-- MP 客戶端 SandboxVars 由伺服器同步，呼叫點（InitPlayer/initDataAndStyle）
-- 皆在 OnGameStart 之後＝安全讀取點（AGENTS.md 沙盒時序）
local function mapAllKnownEnabled()
    return SandboxVars and SandboxVars.Map and SandboxVars.Map.MapAllKnown == true
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
    -- MapAllKnown 補位（小地圖面）
    if mapAllKnownEnabled() then mapAPI:setBoolean("HideUnvisited", false) end
end

-- 外框底色不透明度：縮放 outer／bottomPanel／titleBar 的 backgroundColor.a
-- （原版值首次套用時快照在 _minidoracatBgA，切回「原版」可還原）。
-- 地圖本體是 GPU 直繪（UIElement 無整體 alpha API），只能調整外框視覺重量。
local CHROME_FACTORS = { 1.0, 0.5, 0.15 }
-- 卡片式外框厚度（px）：皮膚圓角（CORNER=6，_Skin.lua:23）需要地圖內容離
-- 外框角落 ≥ 圓角半徑，否則直角地圖貼圖蓋掉圓弧——8＝6 弧＋2 餘裕。
-- 注入點在 InitPlayer 的 ISMiniMapOuter.new 覆寫（createChildren 用它排
-- inner/bottomPanel/adorned 全布局，ISMiniMap.lua:407/419/479-496 連動）
local CHROME_BORDER = 8
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

-- 標題列皮膚化＋透明度：皮膚在（Core.Skin）＝圓上兩角淡填色（TITLEBAR_FILL
-- 疊在外框皮膚底上，同統一設定視窗標題列做法），alphaScale 帶入外框不透明度
-- 因子（Skin.fill 第 8 參，_Skin.lua:108）。皮膚缺席退回原版材質路徑：原版
-- prerender 是單行 alpha=1 材質直繪（ISMiniMap.lua:354-357，
-- drawTextureScaled(titlebarbkg,1,1,w-2,th-2,1,1,1,1)），已畫上去的無法事後
-- 調淡，只能在因子 <1 時以相同引數改 alpha 重畫（忠實複製，引數順序 a,r,g,b）
if ISMiniMapTitleBar and ISMiniMapTitleBar.prerender then
    local originalTitleBarPrerender = ISMiniMapTitleBar.prerender
    function ISMiniMapTitleBar:prerender()
        local f = CHROME_FACTORS[getComboIndex("Opacity", 1)] or 1.0
        if getBoolOption("GhostMode", false) then f = math.min(f, CHROME_FACTORS[3]) end
        local Skin = Core.Skin
        local th = self:titleBarHeight()
        if Skin then
            Skin.fill(self, 0, 0, self.width, th, Skin.COLORS.TITLEBAR_FILL, true, f)
            return
        end
        if f >= 1.0 then return originalTitleBarPrerender(self) end
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
-- 外框每幀調色前置宣告（installMinidoracatButtons 的實例 prerender 要用；
-- 本體在縮放節 resizeState 宣告之後——它讀 resizeState 判拖曳中亮階）
local chromeTintBorder
-- 導航目標表前置宣告（InitPlayer wrapper 要載回 modData；本體與註解見導航一節）
local navTargets = {}
-- 按鈕列擴充前置宣告（InitPlayer 要用；本體見按鈕列一節）。統一設定視窗已拆至
-- MinidoracatMiniMap_Settings.lua，開窗入口改經 Core.toggleSettingsWindow 呼叫時查表
local installMinidoracatButtons

-- 尺寸上限（getPlayerScreenWidth/Height 用例 ISMiniMap.lua:701-702）
local function resizeMax(playerNum)
    return math.floor(math.min(getPlayerScreenWidth(playerNum), getPlayerScreenHeight(playerNum)) * RESIZE_MAX_RATIO)
end

-- 9 顆按鈕（M - + ◇視角 C XY 搜尋 ⚙ X）的最小可容寬度抬高 RESIZE_MIN：必須在 InitPlayer 讀
-- CustomSize 夾限「之前」呼叫——installMinidoracatButtons 的同款回寫發生在視窗建立
-- 之後，救不到舊存小尺寸（如 180x180）的本 session 首次建立（X 鈕會溢出右緣）。
-- 字級在 InitPlayer 時已就緒：鈕寬同原版 BUTTON_HGT 公式 getFontHeight(Small)+6
local function raiseResizeMinForButtons()
    local bw = getTextManager():getFontHeight(UIFont.Small) + 6
    local minW = 9 * bw + 8 * 2 + CHROME_BORDER * 2 + 4 -- 9 鈕＋8×2px 間距＋卡片外框 ×2＋4
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
    -- 導航路線（0.17.0，預設開）：右鍵目標後沿道路畫路線（_NavRoute.lua 全套
    -- 引擎）。純顯示功能不設沙盒 gate；關閉＝退回直線旗標、設目標不觸發建圖。
    -- 例外：開啟搜尋視窗（_Search.lua）仍會 kick 引擎——街名搜尋需要索引，
    -- 索引與 graph 同一條建置流水線（一次性背景成本，非每幀）
    modOptions:addTickBox("NavRoute", "UI_MinidoracatMiniMap_NavRoute", true,
        "UI_MinidoracatMiniMap_NavRoute_tooltip")
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
    -- 區塊形狀（預設開＝整棟一框，0.14.2 起；關＝逐房間）。只作用於區塊模式的
    -- 填色/框線/名稱，圖標錨點不變（POI provider 於整棟模式帶 iconRect 釘住最大
    -- 房間）。⚠ 預設值四點同步：此處、POI.lua 讀取與簽章 fallback、統一視窗
    -- 初始值——不一致的風險在降級/晚註冊路徑（fallback 實際被讀到時）：讀取與
    -- 簽章分歧會漏掉必要重建或多做一次重建，統一視窗則顯示與實際不符
    modOptions:addTickBox("PoiWholeBuilding", "UI_MinidoracatMiniMap_PoiWholeBuilding", true,
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
    log("ISWorldMap.initDataAndStyle not found, mod disabled (game version mismatch?)")
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
    -- MapAllKnown 補位（世界地圖面）：改 instance 欄位而非直寫引擎選項——
    -- ShowWorldMap 每次開圖都以 self.hideUnvisitedAreas 重套
    -- （ISWorldMap.lua:1515），直寫會被蓋回；欄位改 false 則齒輪面板同步一致
    if mapAllKnownEnabled() then self.hideUnvisitedAreas = false end
    local ok, err = pcall(applyMiniMapPyramids, self)
    if not ok then
        log("init failed: " .. tostring(err))
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
                log("remount after world map style rebuild failed: " .. tostring(err))
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
                log("remount on map open failed: " .. tostring(err))
            end
        end
    end
end

-- 首建尺寸決策（純函式，離線測試 scripts/test_minimap_size.lua）：自訂尺寸 >
-- 倍率縮放 > 原版尺寸，一律夾 minWH 下限。下限夾是 8 鈕回歸防護：原版「小」檔
-- inner 寬 6*bw+72，8 鈕最低需 8*bw+14（2px 間距）——2x/3x/4x 字型資產
-- bw=32/39/44 時原版寬各差 6/20/30px，X 鈕溢出右緣（7 鈕時代 bw=44 尚餘 16px，
-- 屬視角鈕新增後的回歸，codex review 以算術抓出）。Core 匿名閉包＝零主 chunk
-- locvar（Kahlua 200 上限對策）
-- test:minimap-size:start
Core.minimapSizeFor = function(width, height, customW, customH, scale, minWH)
    local w = customW or math.floor(width * scale + 0.5)
    local h = customH or math.floor(height * scale + 0.5)
    if w < minWH then w = minWH end
    if h < minWH then h = minWH end
    return w, h
end
-- test:minimap-size:end

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
        -- ISMiniMapOuter.new 改寫寬高」——原版自己用新尺寸排版，零版面補丁。
        -- 一律走覆寫（不再對 scale=1 無自訂尺寸開原版直通道）：原版寬足夠時
        -- w==width、位移 0＝逐位同原版；不足（8 鈕高字級「小」檔）才抬到
        -- RESIZE_MIN，見 Core.minimapSizeFor 註解
        local sizeIndex = getSizeIndex()
        local scale = SIZE_SCALES[sizeIndex]
        raiseResizeMinForButtons() -- 先抬下限再夾 CustomSize（見該函式註解）
        -- 自訂尺寸（邊緣拖曳縮放寫入）存在時優先於下拉倍率
        local customW, customH = getCustomSize(playerNum)
        local minimap
        if ISMiniMapOuter then
            local originalNew = ISMiniMapOuter.new
            ISMiniMapOuter.new = function(self, x, y, width, height, pn)
                local w, h = Core.minimapSizeFor(width, height, customW, customH, scale, RESIZE_MIN)
                -- InitPlayer 以螢幕右下角定位（x = 右緣 - 10 - width），改尺寸後
                -- 平移 x/y 保持右下角錨點不變（prerender 的 setPosition 也會再校正）
                local o = originalNew(self, x + width - w, y + height - h, w, h, pn)
                -- 卡片式粗邊框：new 之後、createChildren（instantiate 觸發）之前改
                -- borderSize（原版 2，ISMiniMap.lua:677）——inner/bottomPanel/adorned
                -- 布局全以它排版（:407/:419/:479-496），零版面補丁（同本 wrap 哲學）
                o.borderSize = CHROME_BORDER
                return o
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
                    log("minimap init failed: " .. tostring(err))
                end
                pcall(applyToggleOptions, minimap.inner.mapAPI)
                -- 街道資料補載：原版小地圖不載 streets.xml（只有世界地圖載，
                -- ISWorldMap.lua:1450），ShowStreetNames 開著也無字可畫。走同一
                -- 函式（ISMapDefinitions.lua:41-49，只用 mapUI.javaObject）——
                -- 翻譯 MOD wrap 它載入的中文街名（CatLangFor42 MapStreets_Flx）一併生效
                -- count==0 gate：initDefaultStreetData 開頭的 clearStreetData
                -- （ISMapDefinitions.lua:44）會走 combinedStreets.clear()——
                -- WorldMapStreets.clear 不清 StreetLookup 空間索引且 42.20.3
                -- 起 ObjectPool 上限 1024 < 官方 1098 條（WorldMap.java:241-248、
                -- WorldMapStreets.java:433-437；LangFor42 AGENTS.md 實證「英文
                -- 街名幽靈殘留」）。Recreate 每次重跑本段，無 gate＝反覆
                -- clear+re-add 踩坑；有 gate＝每實例至多一次 clear-on-empty
                -- （no-op）＋一次載入。LangFor42 wrap（不 clear、只 add）在
                -- 或不在都相容
                if MapUtils and MapUtils.initDefaultStreetData then
                    -- gate 判定整段 pcall：getStreetsAPI 探測異常（API 漂移等）
                    -- 不得炸 InitPlayer 後續（導航目標 modData 載回在本段之後），
                    -- 且判定失敗＝退回 0.16 無條件補載——寧可重踩 clear 坑也
                    -- 不可靜默丟街名（claude review：gate 失效面）
                    local gateOk, isEmpty = pcall(function()
                        return minimap.inner.mapAPI:getStreetsAPI():getStreetDataCount() == 0
                    end)
                    if not gateOk or isEmpty then
                        pcall(MapUtils.initDefaultStreetData, minimap.inner)
                    end
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
                PZAPI.ModOptions:save() -- 立即落地 ModOptions.ini（PZAPI/ModOptions.lua:259）
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
-- 按鈕列擴充（定位玩家／複製座標改用共用 icon；缺框架退回 C／XY）
-- 統一設定視窗整節（UNIFIED_* 資料表、unifiedRebuild、buildSettingsWindow、
-- toggleSettingsWindow 等）已拆至 MinidoracatMiniMap_Settings.lua（Kahlua 每原型
-- locvar 上限 200 對策）；主檔僅留按鈕列與開窗入口，呼叫時查
-- Core.toggleSettingsWindow＋nil 防呆（模組檔載入序在本檔之後）。
--------------------------------------------------------------------------------
-- test:minimap-toolbar-icons:start
local function toolbarIconButtonRender(self)
    ISButton.render(self)
    local Skin = Core.Skin
    local key = self._minidoracatIconKey
    local owner = self._minidoracatIconOwner
    local active = key == "locate" and owner and owner.inner
        and owner.inner._minidoracatFreelook and getBoolOption("FreeLook", true)
    local color
    if Skin then
        if active then
            color = Skin.COLORS.ACCENT_AMBER
        elseif key == "locate" and not self.mouseOver then
            color = Skin.COLORS.TEXT_MUTED
        else
            color = self.mouseOver and Skin.COLORS.ACCENT_AMBER or Skin.COLORS.TEXT_PRIMARY
        end
    end
    local size = math.max(8, math.min(16, self.width - 6, self.height - 6))
    local x, y = math.floor((self.width - size) / 2), math.floor((self.height - size) / 2)
    if Skin and Skin.icon and Skin.icon(self, key, x, y, size, color) then return end
    local fontH = getTextManager():getFontHeight(UIFont.Small)
    self:drawTextCentre(self._minidoracatFallback, self.width / 2,
        math.floor((self.height - fontH) / 2),
        color and color.r or 0.8, color and color.g or 0.8,
        color and color.b or 0.8, 1, UIFont.Small)
end

local function installToolbarIcon(button, owner, key, fallback)
    button:setTitle("")
    button:setImage(nil)
    button._minidoracatIconKey = key
    button._minidoracatIconOwner = owner
    button._minidoracatFallback = fallback
    button.render = toolbarIconButtonRender
end
-- test:minimap-toolbar-icons:end

-- 按鈕列重排：9 顆（M - + ◇視角 定位 複製 尋 ⚙ X）以動態間距塞進 inner 寬度
-- （原版置中排版只按 5 顆算，ISMiniMap.lua:417）
local function relayoutBottomButtons(mm)
    -- 逐鈕 append＋顯式計數：候選含可缺席鈕（perspBtn 材質降級＝nil），
    -- 表構造子中間 nil 會讓 # 截斷（Kahlua len 二分探邊界，KahluaUtil.java:436-452
    -- ——先前僅因 nil 落點錯開探點而僥倖正確；家規「# 不可信」count/rn 慣例）
    local btns, bn = {}, 0
    local function addBtn(b)
        if b then bn = bn + 1; btns[bn] = b end
    end
    addBtn(mm.button1)
    addBtn(mm.button2)
    addBtn(mm.button3)
    addBtn(mm._minidoracatPerspBtn)
    addBtn(mm._minidoracatCenterBtn)
    addBtn(mm._minidoracatCopyBtn)
    addBtn(mm._minidoracatSearchBtn)
    addBtn(mm.button4)
    addBtn(mm.button6)
    local n = bn
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
        log("copy coords failed: Clipboard global unavailable")
        return
    end
    local ok, err = pcall(Clipboard.setClipboard, text)
    if not ok then
        log("copy coords failed: " .. tostring(err))
    elseif inner then
        inner._minidoracatCopiedUntil = getTimestampMs() + 1500
    end
end

installMinidoracatButtons = function(mm)
    if not (mm and mm.bottomPanel and mm.button4 and ISButton) then return end
    local ref = mm.button4
    -- 定位玩家（缺框架退回「C」）：清自由查看旗標，下一幀 prerenderHack 恢復回中
    local cBtn = ISButton:new(0, ref.y, ref.width, ref.height, "C", mm, function(target)
        if target.inner then target.inner._minidoracatFreelook = nil end
    end)
    cBtn:initialise()
    -- 樣式由本函式尾端「按鈕列皮膚化」迴圈統一覆蓋（單一真相源）
    cBtn.tooltip = getText("UI_MinidoracatMiniMap_BtnCenter") -- ISButton 內建 tooltip（ISButton.lua:317-321）
    installToolbarIcon(cBtn, mm, "locate", "C")
    mm.bottomPanel:addChild(cBtn)
    mm._minidoracatCenterBtn = cBtn
    -- 複製座標（缺框架退回「XY」）：格式 x,y,z（原版 /teleportto x,y,0 相容；
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
    copyBtn.tooltip = getText("UI_MinidoracatMiniMap_BtnCopyCoords")
    installToolbarIcon(copyBtn, mm, "copy", "XY")
    mm.bottomPanel:addChild(copyBtn)
    mm._minidoracatCopyBtn = copyBtn
    -- 視角切換（等軸測↔俯視）：同世界地圖 perspectiveBtn（ISWorldMap.lua:329-332、
    -- onChangePerspective :1042-1044、setIsometric＝mapAPI:setBoolean("Isometric")
    -- :1127-1130）；材質同原版（:1480-1481，48px，forceImageSize 縮進鈕面——
    -- ISButton.lua:187-190/221-222）。與統一視窗「圖層顯示」的等軸測勾選
    -- （_Settings UNIFIED_LAYER_TICKS engine=true）同一顆小地圖引擎布林＝同源：
    -- 按鈕圖每幀值變才換（原版 WM prerender 讀值同步先例 :394-397），視窗/ESC
    -- 改動不脫鉤；toggle 後同玩家的設定視窗開著即重建（Core.refreshSettingsWindow，
    -- 同 PlaceNames tick 重建先例），勾選框立即反映。持久化＝原版既有流程
    -- （saveSettings 存 MiniMap.Isometric，ISMiniMap.lua:605-616；ISPlayerData.lua:60
    -- 觸發；:606 閘門＝僅 player 0 寫入——P2+ 本場即時生效、跨場不保存，原版限制）。
    -- 材質缺失＝不建鈕（order 表 nil 自動過濾、n 動態）——降級安全
    local texIso = getTexture("media/textures/worldMap/ViewIsometric.png")
    local texOrtho = getTexture("media/textures/worldMap/ViewOrtho.png")
    if texIso and texOrtho then
        local perspBtn = ISButton:new(0, ref.y, ref.width, ref.height, "", mm, function(target)
            local api = target.inner and target.inner.mapAPI
            if not api then return end
            api:setBoolean("Isometric", not api:getBoolean("Isometric"))
            if Core.refreshSettingsWindow then
                pcall(Core.refreshSettingsWindow, target.playerNum or 0)
            end
        end)
        perspBtn:initialise()
        perspBtn.tooltip = getText("UI_MinidoracatMiniMap_BtnPerspective")
        perspBtn:forceImageSize(ref.width - 8, ref.height - 8)
        local originalPerspPrerender = perspBtn.prerender
        perspBtn.prerender = function(self)
            local api = mm.inner and mm.inner.mapAPI
            local iso = api and api:getBoolean("Isometric") or false
            if iso ~= self._minidoracatIso then -- 值變才 setImage（首幀 nil≠布林必設）
                self._minidoracatIso = iso
                self:setImage(iso and texIso or texOrtho)
            end
            originalPerspPrerender(self)
        end
        mm.bottomPanel:addChild(perspBtn)
        mm._minidoracatPerspBtn = perspBtn
    end
    -- 放大鏡地圖搜尋：座標／街名／設施類別（視窗本體在 _Search.lua；
    -- Core.toggleSearchWindow 於該檔載入期掛出，事件期呼叫必已就緒）。
    -- icon＝原版 media/ui/Search_Icon_On.png（原版搜尋欄同款，風格一致）；
    -- 材質缺時退回單字 label（翻譯鍵 fallback，同 perspBtn 的缺材質防線）
    local texSearch = getTexture("media/ui/Search_Icon_On.png")
    local searchBtn = ISButton:new(0, ref.y, ref.width, ref.height,
        texSearch and "" or getText("UI_MinidoracatMiniMap_BtnSearchLabel"), mm, function(target)
        if Core.toggleSearchWindow then
            Core.toggleSearchWindow(target.playerNum or 0, target.inner)
        end
    end)
    searchBtn:initialise()
    searchBtn.tooltip = getText("UI_MinidoracatMiniMap_BtnSearch")
    if texSearch then
        searchBtn:setImage(texSearch)
        searchBtn:forceImageSize(ref.width - 8, ref.height - 8)
    end
    mm.bottomPanel:addChild(searchBtn)
    mm._minidoracatSearchBtn = searchBtn
    -- 「=」圖層面板鈕已退役：引擎原生三項移入統一視窗「圖層顯示」區。
    -- 原版面板機制（getVisibleOptions/onTickBox wrap 等）保留不拆——
    -- 面板已無入口，但第三方 MOD 若開啟它，注入與回寫仍正確
    mm.button4.tooltip = getText("UI_MinidoracatMiniMap_BtnSettings")
    -- 原版按鈕補 tooltip（M/-/+/X 原版無滑鼠提示；tooltip 欄位同上）
    if mm.button1 then mm.button1.tooltip = getText("UI_MinidoracatMiniMap_BtnWorldMap") end
    if mm.button2 then mm.button2.tooltip = getText("UI_MinidoracatMiniMap_BtnZoomOut") end
    if mm.button3 then mm.button3.tooltip = getText("UI_MinidoracatMiniMap_BtnZoomIn") end
    if mm.button6 then mm.button6.tooltip = getText("UI_MinidoracatMiniMap_BtnClose") end
    -- 按鈕列皮膚化：9 顆（原版 5＋本 MOD 4）統一淡框淡底＋hover 亮階——同
    -- _Settings unifiedAddBtn 樣式（fade 混色 ISButton:prerender :117-133、
    -- 守衛 shouldDrawBackground/shouldDrawBorder :91-100）。鈕底半透明化後
    -- 露出 outer 黑 0.8 底（ISMiniMap.lua:675），與統一設定視窗同基調。
    -- 逐鈕呼叫、不經中間表：perspBtn 材質缺失時為 nil，表構造子中間 nil
    -- 會讓 # 截斷（家規「Kahlua # 不可信」，同 POIExport count/rn 慣例）
    local function skinBtn(b)
        if not b then return end
        b.borderColor = { r = 0.55, g = 0.55, b = 0.55, a = 0.35 }
        b.backgroundColor = { r = 1, g = 1, b = 1, a = 0.05 }
        b.backgroundColorMouseOver = { r = 1, g = 1, b = 1, a = 0.16 }
    end
    skinBtn(mm.button1)
    skinBtn(mm.button2)
    skinBtn(mm.button3)
    skinBtn(mm.button4)
    skinBtn(mm.button6)
    skinBtn(cBtn)
    skinBtn(copyBtn)
    skinBtn(mm._minidoracatPerspBtn)
    skinBtn(searchBtn)
    local n = relayoutBottomButtons(mm) or 9
    -- n 顆按鈕的最小可容寬度回寫尺寸下限（n＝order 表實際數量，單一來源）：UI 字型
    -- 放大時 BUTTON_HGT 跟著變大，動態墊高避免縮到溢出。InitPlayer 另以
    -- raiseResizeMinForButtons 在 CustomSize 夾限前先抬——本回寫發生在視窗建立後，
    -- 只服務「本 session 後續拖曳」的下限
    local minW = n * ref.width + (n - 1) * 2 + (mm.borderSize or 2) * 2 + 4
    if minW > RESIZE_MIN then RESIZE_MIN = minW end
    -- ponytail: C/XY/視角/搜尋 四顆新鈕都未登記手把導航列（原版 insertNewLineOfButtons 於
    -- createChildren 一次性登記，事後補列會亂序）——手把用戶：顯示開關走 ESC 選項頁、
    -- 視角另有兩條可達路徑（原版小地圖選項面板 Isometric 勾選 ISMiniMap.lua:104、
    -- 世界地圖 perspectiveBtn），複製功能手把不可達（滑鼠限定）；搜尋亦滑鼠限定
    -- （放大鏡鈕＋兩處右鍵選單皆無手把路徑）——目前無替代入口，需要時再補登記
    -- 外框皮膚化：替換實例 prerender——重演原版邏輯（ISMiniMap.lua:452-468，
    -- 42.20.3 原文：setPosition＋adornments hover 判斷＋inner:prerenderHack），
    -- 僅把直角 drawRectStatic/drawRectBorderStatic（:462-463）換成圓角皮膚。
    -- 升版檢查點：原版 prerender 三件套若有變，此處同步。
    -- 實例欄位會遮蔽下方 class 層 ISMiniMapOuter:prerender wrap（穿透琥珀
    -- ／hover 邊框調色，三 lane review 抓出）——調色抽成 chromeTintBorder
    -- 單一實作，繪製前呼叫；class wrap 續存兜底未走本函式的實例。
    -- backgroundColor.a 由 applyChromeOpacity 縮放（透明度/穿透鏈自動生效）；
    -- setAdornmentsVisible 走 self 動態查找＝「永遠顯示」wrap 照常攔截。
    -- Skin 缺席退回原版直角同款繪製
    mm.prerender = function(self)
        self:setPosition()
        if self.joyfocus or (not (self.inner.dragging and self.inner.dragMoved) and self:isMouseOver())
            or self.titleBar:isMouseOver() or self.titleBar.dragging then
            self:setAdornmentsVisible(true)
        else
            self:setAdornmentsVisible(false)
        end
        if chromeTintBorder then chromeTintBorder(self) end
        local Skin = Core.Skin
        if Skin then
            Skin.fill(self, 0, 0, self.width, self.height, self.backgroundColor)
            Skin.border(self, 0, 0, self.width, self.height, self.borderColor)
        else
            self:drawRectStatic(0, 0, self.width, self.height,
                self.backgroundColor.a, self.backgroundColor.r, self.backgroundColor.g, self.backgroundColor.b)
            self:drawRectBorderStatic(0, 0, self.width, self.height,
                self.borderColor.a, self.borderColor.r, self.borderColor.g, self.borderColor.b)
        end
        self.inner:prerenderHack()
    end

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
-- test:csv-set:start
local function unifiedCsvSet(raw)
    local set = {}
    for w in string.gmatch(tostring(raw or ""), "[^,]+") do
        if w ~= "-" and w ~= "nil" then set[w] = true end
    end
    return set
end
-- test:csv-set:end


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
        print("[MinidoracatMiniMap] registerAnimalGroup: bad arguments"
            .. " (need ownerModId, group, labelKey; art paths optional but not empty; group must not contain commas or reserved values)")
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
                    .. "' is already used by another species definition (from " .. ownerModId .. ")")
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
    local pn = inner.playerNum or 0
    local dist = displayDist("SafehouseDisplayDistance", pn)
    -- 顯示模式：1=關閉、2=僅自己的、3=全部（預設；缺表視為 3）。管理員隱私檢視
    -- 生效時取最寬模式（3）且距離閘一併放行——旁路只影響「這台客戶端畫什麼」
    local shMode = safehouseDisplayMode(pn)
    if shMode == 1 then return end
    local list = SafeHouse.getSafehouseList()
    if not list or list:size() == 0 then return end
    -- getSpecificPlayer/getX/getY 原版用例 ISMiniMap.lua:216-222；getUsername 原版用例
    -- ISScoreboard.lua:108。距離啟用但缺玩家時全部 fail closed
    local playerObj = getSpecificPlayer(pn)
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
-- Zone 圖層繪製（fill/lines/icons 三 pass＋ZC 候選快取）已拆至
-- MinidoracatMiniMap_Zones.lua（Kahlua 主 chunk locvar 上限對策，2026-09-03）。
-- 主檔只留呼叫入口：模組檔載入序在本檔之後，呼叫時查 Core.*；模組缺席（載入
-- 失敗）時依 flagKey log-once 可診斷（同 _Dots 的 pcall(nil) 慣例），不炸 prerender。
-- Core 匿名閉包＝零主 chunk locvar。
--------------------------------------------------------------------------------
Core.drawZonePass = function(inner, pass, flagKey)
    local fn = Core[pass]
    if fn then return Core.safeDrawZone(inner, fn, flagKey) end
    if not inner[flagKey] then
        inner[flagKey] = true
        log("zone pass " .. tostring(pass) .. " unavailable (_Zones module missing)")
    end
end

-- 世界地圖（M）同步畫框線：wrap prerender（原版 prerender＝ISWorldMap.lua:363）。
-- 時序同小地圖側（ISMiniMapInner:prerender）：引擎地圖畫在底、Lua prerender 疊加
-- 於其上，子元件（按鈕列/圖例/符號面板）之後才畫、蓋在最上——框線不遮 UI 控件
--（掛 render 會畫在子元件之後、蓋住按鈕列）。
if ISWorldMap and ISWorldMap.prerender then
    local originalWorldMapPrerender = ISWorldMap.prerender
    function ISWorldMap:prerender()
        -- Zone 填色置於 wrap 最前端＝最底層：Java 地圖本體早在 Lua prerender 前畫完
        -- （UIWorldMap.java:152→317），置頂即壓在 base map 之上、動物圖標與框線之下
        Core.drawZonePass(self, "drawZoneFill", "_minidoracatWMZoneFillErrLogged")
        -- 世界地圖圖標：獨立 WM* 開關（統一視窗「世界地圖圖標」區），
        -- 風格/顏色/篩選與小地圖共用。客戶端只知道已載入區域的個體，
        -- 拉遠不會鋪滿全圖——圖標天然只出現在玩家周邊。
        -- 畫在 original prerender「之前」：引擎地圖本體在 Java 層早已畫完
        -- （UIWorldMap.java:152→317 才進 Lua prerender），而 original 內含
        -- 註記編輯預覽（ISWorldMapSymbols.lua:1459）——先畫圖標，預覽才不被反蓋。
        -- 持久繪製錯誤首次記 log（同小地圖動物繪製的 log-once 策略）。
        -- 點雲本體在 _Dots.lua（主 chunk locvar 上限拆檔），Core.* 動態查：
        -- 模組缺席（載入失敗）時 pcall(nil) 回 false，照走 log-once 可診斷
        local adOk, adErr = pcall(Core.drawAnimalDots, self, "WMAnimalWild", "WMAnimalLivestock", "WMVehicleDots")
        if not adOk and not self._minidoracatWMADotsErrLogged then
            self._minidoracatWMADotsErrLogged = true
            log("world map animal icons draw failed: " .. tostring(adErr))
        end
        local zdOk, zdErr = pcall(Core.drawZombieDotsOn, self, "WMZombieDots")
        if not zdOk and not self._minidoracatWMZDotsErrLogged then
            self._minidoracatWMZDotsErrLogged = true
            log("world map zombie dots draw failed: " .. tostring(zdErr))
        end
        originalWorldMapPrerender(self)
        pcall(drawMapBounds, self)
        Core.drawZonePass(self, "drawZoneLines", "_minidoracatWMZoneLineErrLogged") -- 與 MapBounds 同層
        Core.drawZonePass(self, "drawZoneIcons", "_minidoracatWMZoneIconErrLogged") -- POI 圖標，同層
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
            -- 放大鏡搜尋鈕（實測回饋：大地圖找不到搜尋入口——右鍵選單之外補
            -- 按鈕）；self 兼 NavRoute 引擎冷啟動的 mapAPI 載體（同右鍵選單）
            local searchBtn = ISButton:new(self.closeBtn.x, 0, btnSize, btnSize, "", self,
                function(target)
                    if Core.toggleSearchWindow then
                        Core.toggleSearchWindow(target.playerNum or 0, target)
                    end
                end)
            searchBtn:initialise()
            local texSearch = getTexture("media/ui/Search_Icon_On.png")
            if texSearch then
                searchBtn:setImage(texSearch)
                searchBtn:forceImageSize(math.floor(btnSize * 0.6), math.floor(btnSize * 0.6))
            else
                searchBtn:setTitle(getText("UI_MinidoracatMiniMap_BtnSearchLabel"))
            end
            searchBtn.tooltip = getText("UI_MinidoracatMiniMap_BtnSearch")
            self.buttonPanel:addChild(searchBtn)
            local btn = ISButton:new(searchBtn:getRight() + 10, 0, btnSize, btnSize, "", self,
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
            self._minidoracatWMSearchBtn = searchBtn
            -- ponytail: 未登記手把導航列（同小地圖新鈕的取捨——事後補列會亂序），
            -- 手把用戶走 ESC 選項頁（PZAPI ModOptions 已列全部開關；引擎原生三項
            -- 原版世界地圖選項面板本就可及），需要時再補登記
        end)
        if not ok then
            log("world map paw button install failed: " .. tostring(err))
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
            log("world map options panel imagery toggle injection failed: " .. tostring(err))
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
-- ⚠ AllowNavShare 是「會影響其他玩家／需伺服器轉送」的功能閘，**永不**列入管理員
-- 旁路白名單；政策模組缺席時與伺服器端同樣 fail-closed，避免客戶端顯示可分享、
-- 伺服器卻拒絕的靜默不一致。匿名掛 Core，避免增加主 chunk local。
-- test:nav-share-policy:start
Core.navShareAllowed = function()
    if Policy then return Policy.readBool("AllowNavShare", true) == true end
    if not Core.navPolicyMissingLogged then
        Core.navPolicyMissingLogged = true
        log("policy facade missing; navigation sharing disabled")
    end
    return false
end
-- test:nav-share-policy:end
local lastAllowNavShare = Core.navShareAllowed()
-- test:nav-share-gate:start
local function navShareGateTick()
    local allowed = Core.navShareAllowed()
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
    if not Core.navShareAllowed() then return end
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

-- 導航動作共用實作（Core 匿名閉包＝零主 chunk locvar 成本，Kahlua 200 上限對策）：
-- 小地圖（ISMiniMapInner，本檔）與世界地圖（ISWorldMap，_WorldMapNav.lua）兩面
-- 共用同一批狀態與持久化路徑；世界地圖模組檔載入在後，經 Core 命名空間取用
Core.navGetTarget = function(pn) return navTargets[pn] end
-- NavRoute 分享路線用：回「給此玩家的分享目標桶」（[author]={x,y}）；沙盒
-- 閘門與旗標繪製同源——閘門關閉時旗與路線一起消失，不會旗滅線存
Core.navGetShared = function(pn)
    if not Core.navShareAllowed() then return nil end
    local playerObj = getSpecificPlayer(pn)
    return playerObj and sharedTargets[playerObj:getUsername()] or nil
end
-- 分享目標配色盤：首色紅（單一分享者＝紅，使用者回饋要與自己的青色路線
-- 明確區分）；多分享者以作者名穩定 hash 輪色——同人跨場恆同色。色盤避開
-- 自己的金旗與路線青色
local SHARE_COLORS = {
    { 1.0, 0.25, 0.25 }, -- 紅
    { 1.0, 0.62, 0.15 }, -- 橙
    { 0.75, 0.45, 1.0 }, -- 紫
    { 0.3, 0.95, 0.4 },  -- 綠
    { 1.0, 0.5, 0.8 },   -- 粉
    { 0.65, 0.9, 0.2 },  -- 黃綠
}
Core.navShareColor = function(author)
    local h = 0
    -- string.byte：Kahlua 有註冊但原版無用例（AGENTS.md）——pcall 降級為長度
    local ok = pcall(function()
        for i = 1, #author do h = h + author:byte(i) * i end
    end)
    if not ok then h = #author end
    local c = SHARE_COLORS[(h % #SHARE_COLORS) + 1]
    return c[1], c[2], c[3]
end
-- Addon 導航閘門（nav API；首個消費者＝MinidoracatAutoDriveFor42 的
-- 「GPS 導航儀道具」gating，見 docs/plan-autodrive-addon.md M1）：註冊表與
-- 錯誤旗標一律掛 Core／API 表——主檔主 chunk locvar 已頂 Kahlua 200 上限
-- （LexState actvar[200] 固定陣列、頂層 local 永不出 scope），本節不得增頂層 local。
-- 契約：gateFn(playerNum, context) → (allowed, reasonKey)，context＝"set"
-- （寫入目標前）／"draw"（路線與旗標繪製前）兩值。明確回 false 才擋，nil／
-- 其他值一律放行——addon 忘了 return 不該讓整組導航靜默死掉。第二回傳
-- reasonKey＝翻譯鍵字串（選填）：被擋時由 navSetTarget 拿去做 halo 提示，
-- 讓 addon 能說出「缺 GPS 導航儀」；缺省或非字串則退回主 MOD generic 鍵。
-- 多 gate 為 AND（任一擋即擋，回報第一個擋阻者的 reasonKey）。gateFn
-- 拋錯＝fail-open 並依 owner 每場只 log 一次（同 zoneProviderErrorOnce 慣例：
-- 外部程式碼壞掉不得讓核心功能連坐，更不得每幀刷屏）。零註冊時行為與加
-- API 前逐位元相同（addon 不裝零影響）。
-- test:nav-gate:start
-- v4：requestRoute／requestDetour 的參數與 v1-v3 route 欄位不變；route additive
-- 新增逐段 segSurface/segWidth（與 pts 段數嚴格對齊）、數值 cost/avoidPenalty、
-- approachSurface 與 patchState="applied"|"raw"。舊版消費者仍可只讀既有欄位。
-- v5（2026-09-02）：欄位與簽名全同 v4，只修 route.snapDist 語意——沿用快取時刷新成
-- 「玩家→路線最近點」的投影距離（＝偏航 d），不再是「玩家→pts[1]」；v4 在沿線前進後
-- 停車再查會把在線上的車報成起點百公尺外。消費者以 navApiVersion>=5 判定可否信任
-- snapDist 當「起點太遠」門檻（AutoDrive 對 v4 不套此門檻）。
MinidoracatMiniMapAPI.navApiVersion = 5
Core.navGates = {} -- { { owner=, fn=, errLogged= }, ... }
function MinidoracatMiniMapAPI.registerNavGate(ownerModId, gateFn)
    if type(ownerModId) ~= "string" or ownerModId == "" or type(gateFn) ~= "function" then
        log("registerNavGate bad arguments (need ownerModId string, gateFn function)")
        return false
    end
    local gates = Core.navGates
    for i = 1, #gates do
        if gates[i].owner == ownerModId then
            -- 同 owner 重註冊＝覆蓋（addon 條件換實作/熱重載不留舊 gate 疊加）；
            -- 錯誤旗標一併重置——新 fn 的錯誤值得記一次新 log
            gates[i].fn = gateFn
            gates[i].errLogged = nil
            return true
        end
    end
    gates[#gates + 1] = { owner = ownerModId, fn = gateFn }
    return true
end
-- 閘門查詢（繪製路徑每幀呼叫：零註冊在 #gates 後即返回，無配置、無 pcall）
Core.navGateAllows = function(playerNum, context)
    local gates = Core.navGates
    local n = #gates
    if n == 0 then return true end
    for i = 1, n do
        local g = gates[i]
        -- 第三回傳位＝gateFn 的 reasonKey（pcall 成功時）；拋錯時第二位是錯誤訊息
        local ok, allowed, reasonKey = pcall(g.fn, playerNum, context)
        if not ok then
            if not g.errLogged then
                g.errLogged = true
                log("nav gate error (" .. tostring(g.owner) .. "): " .. tostring(allowed))
            end
        elseif allowed == false then
            return false, reasonKey
        end
    end
    return true
end
-- 回 (ok, reasonKey)：ok=true＝已寫入目標；false＝無玩家或被 gate 擋。
-- 被擋必須「看得見」：右鍵選單／搜尋視窗設目標是玩家主動操作，靜默失敗＝
-- 玩家以為功能壞掉（silent-failure review 指認）。走原版 halo 壞訊息通道
-- （HaloTextHelper.addBadText，原版用例 ISVehicleMenu.lua:1197 等），addon 的
-- reasonKey 優先（能明說「缺 GPS 導航儀」），缺省／非字串退回主 MOD generic
-- 鍵。第二回傳＝實際用掉的鍵（供呼叫端與測試判斷）；無玩家時無提示亦無鍵
Core.navSetTarget = function(pn, worldX, worldY)
    local playerObj = getSpecificPlayer(pn)
    if not playerObj then return false end
    local allowed, reasonKey = Core.navGateAllows(pn, "set")
    if not allowed then
        if type(reasonKey) ~= "string" or reasonKey == "" then
            reasonKey = "UI_MinidoracatMiniMap_NavBlocked"
        end
        HaloTextHelper.addBadText(playerObj, getText(reasonKey))
        return false, reasonKey
    end
    navTargets[pn] = { x = worldX, y = worldY }
    navSaveModData(playerObj, navTargets[pn])
    if navShared[pn] then Core.navShareTarget(pn) end -- 分享中：移動即重新廣播
    return true
end
-- 目前導航目標查詢（nav API v2；消費者＝MinidoracatAutoDriveFor42 M3 自駕核心，
-- 見 docs/plan-autodrive-addon.md §5）。回「兩個純量」而非內部 table 是刻意的：
-- navTargets[pn] 是主 MOD 的持久化狀態本體，交出參考等於讓 addon 能繞過
-- Core.navSetTarget（唯一含 gate＋modData 持久化的寫入口）改目標——而且改了
-- 還不會重播分享、不會存檔，是最難查的一類靜默不一致。複製一份 {x=,y=} 也不
-- 行：自駕迴路每幀查目標，每幀配置一個 table＝白送 Kahlua GC 壓力。
-- 回 (x, y)＝兩個 number；(nil, reason) 表無值，reason＝
--   "badargs"（playerNum 非 0-3 整數）／"notarget"（該槽位目前無導航目標）
-- badargs 從嚴同 requestRoute：非整數／越界槽位會靜靜讀到別人的（或不存在的）
-- 槽位，錯得無聲。本函式不查 player（純狀態讀取，槽位無人時 navTargets 自然
-- 是 nil＝notarget）、不寫任何狀態、零配置——自駕熱路徑可直接每幀呼叫。
function MinidoracatMiniMapAPI.getNavTarget(playerNum)
    -- 先擋 NaN（自比不等；範圍比較對 NaN 恆為 false 擋不住），再擋越界／非整數
    -- （±Infinity 由範圍比較擋下，故 % 1 只需處理有限值）
    if type(playerNum) ~= "number" or playerNum ~= playerNum
        or playerNum < 0 or playerNum > 3 or playerNum % 1 ~= 0
    then
        return nil, "badargs"
    end
    local t = navTargets[playerNum]
    if not t then return nil, "notarget" end
    return t.x, t.y
end
-- test:nav-gate:end
Core.navClearTarget = function(pn)
    local playerObj = getSpecificPlayer(pn)
    if playerObj then navClear(pn, playerObj) end
end
Core.navShareTarget = function(pn)
    local playerObj = getSpecificPlayer(pn)
    local t = navTargets[pn]
    if not (playerObj and t and isClient()) then return end
    if not Core.navShareAllowed() then return end -- 伺服器沙盒禁用／政策模組缺席
    navShared[pn] = true
    sendClientCommand(playerObj, "MinidoracatMiniMap", "shareTarget", { x = t.x, y = t.y })
end

-- 導航目標載回：掛 OnCreatePlayer（原版用例 ISPlayerData.lua:203、簽名同
-- ISPerkLog.logCreatePlayer(_player)＝playerIndex）而非只靠 ISMiniMap.InitPlayer
-- ——InitPlayer 受沙盒 AllowMiniMap 閘門（ISPlayerDataObject.lua:139-141），
-- 關閉時不跑，世界地圖側（_WorldMapNav.lua）會漏載持久目標、或讀到同槽位
-- 上一位角色的殘值（三 lane review 抓出）。InitPlayer 的載回段保留（Recreate
-- 重建路徑同步），兩處讀同一 modData、冪等
Events.OnCreatePlayer.Add(function(pn)
    local playerObj = getSpecificPlayer(pn)
    if not playerObj then return end
    local md = playerObj:getModData()
    if md and md.MinidoracatMiniMapTX and md.MinidoracatMiniMapTY then
        navTargets[pn] = { x = md.MinidoracatMiniMapTX, y = md.MinidoracatMiniMapTY }
    else
        navTargets[pn] = nil -- 新角色/無目標：清同槽位舊角色殘值
    end
end)

-- 右鍵選單回呼（addOption 簽名同原版 debug 傳送項 ISMiniMap.lua:292）
function ISMiniMapInner:onMinidoracatSetTarget(worldX, worldY)
    Core.navSetTarget(self.playerNum or 0, worldX, worldY)
end

function ISMiniMapInner:onMinidoracatClearTarget()
    Core.navClearTarget(self.playerNum or 0)
end

function ISMiniMapInner:onMinidoracatShareTarget()
    Core.navShareTarget(self.playerNum or 0)
end

function ISMiniMapInner:onMinidoracatSearch()
    if Core.toggleSearchWindow then
        Core.toggleSearchWindow(self.playerNum or 0, self)
    end
end

-- 旗標：黑框桿＋色旗（drawRect 疊法同殭屍點描邊）；label（分享者名）與 dist
-- （距離公尺）分兩行掛旗上——同行擠在一起難讀（使用者回饋），名字上、距離下
local function drawNavFlag(inner, ux, uy, r, g, b, label, dist)
    inner:drawRect(ux - 2, uy - 14, 4, 15, 0.8, 0, 0, 0)
    inner:drawRect(ux - 1, uy - 13, 2, 13, 1, 1, 1, 1)
    inner:drawRect(ux, uy - 14, 11, 8, 0.8, 0, 0, 0)
    inner:drawRect(ux + 1, uy - 13, 9, 6, 1, r, g, b)
    -- 深色底墊字（同原版玩家名牌做法 UIWorldMap.java:509），淺色地圖上才清晰；
    -- 位置夾進視窗（長名字貼上/右緣時不外溢）。Medium 字級＋離旗 10/44px
    local w, h = inner.width, inner.height
    local lines = {}
    -- 作者名行用旗色（隊友 ID 與其路線/旗同色一眼對應，使用者回饋）；距離行
    -- 維持白色（讀數清晰）
    if label then lines[#lines + 1] = { t = label, cr = r, cg = g, cb = b } end
    if dist then lines[#lines + 1] = { t = tostring(dist) .. "m", cr = 1, cg = 1, cb = 1 } end
    local ly = uy - 44 - (#lines - 1) * 22 -- 多行往上長，最下行維持離旗 44px
    for i = 1, #lines do
        local ln = lines[i]
        local tw = getTextManager():MeasureStringX(UIFont.Medium, ln.t)
        local lx = ux + 10
        if lx < 2 then lx = 2 elseif lx > w - tw - 2 then lx = w - tw - 2 end
        local cy2 = ly + (i - 1) * 22
        if cy2 < 2 then cy2 = 2 elseif cy2 > h - 22 then cy2 = h - 22 end
        inner:drawRect(lx - 4, cy2 - 1, tw + 8, 22, 0.6, 0, 0, 0)
        inner:drawText(ln.t, lx, cy2, ln.cr, ln.cg, ln.cb, 0.95, UIFont.Medium) -- drawText＝ISUIElement.lua:1293
    end
end

-- 目標在視窗內＝旗標；出視窗＝中心→目標線段裁到內縮 12px 矩形（重用 clipSegment），
-- 交點畫 V 形箭頭（翼向量＝方向單位向量旋 ±25.8°，c=0.9/s=0.436，免 atan）
local function drawNavIndicator(inner, tx, ty, r, g, b, label, dist)
    local w, h = inner.width, inner.height
    if tx >= 8 and ty >= 16 and tx <= w - 14 and ty <= h - 4 then
        drawNavFlag(inner, tx, ty, r, g, b, label, dist) -- 名字/距離分行由旗標函式排版
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
        -- MeasureStringX 用例 ISFactionUI.lua:238；Medium 字級同旗標 label
        local tw = getTextManager():MeasureStringX(UIFont.Medium, txt)
        local px = tipx - uxn * 28 - tw / 2
        local py = tipy - uyn * 28 - 10
        if px < 2 then px = 2 elseif px > w - tw - 2 then px = w - tw - 2 end
        if py < 2 then py = 2 elseif py > h - 22 then py = h - 22 end
        -- 深色底墊字（同原版玩家名牌做法 UIWorldMap.java:509），淺色地圖上才清晰
        inner:drawRect(px - 4, py - 1, tw + 8, 22, 0.6, 0, 0, 0)
        inner:drawText(txt, px, py, 1, 1, 1, 0.95, UIFont.Medium)
    end
end

-- test:nav-draw:start（scripts/test_nav_gate.lua 抽本區段跑 draw gate 整合測試）
local function drawNavTargets(inner)
    local pn = inner.playerNum or 0
    -- Addon 閘門（context="draw"）：只擋「導航目標層繪製與路線計算」——搜尋
    -- 落點 ping 不屬導航目標層（搜尋是獨立功能，不該被導航道具連坐），抵達
    -- 清除與狀態收尾亦照跑：那是狀態變更，擋掉會讓玩家走到目標後目標永久
    -- 黏著（同 navCheckArrival 註解的「早退不得連坐狀態更新」理由）
    local allowed = Core.navGateAllows(pn, "draw")
    -- 路線層（_NavRoute.lua 掛 Core.drawNavRoute）：先畫＝墊在旗標/箭頭/分享旗
    -- 之下。收 err＋實例旗標 log-once（同動物繪製/_WorldMapNav 慣例：主檔
    -- :4022-4027 明寫「持久錯誤首次記 log 免全靜默」——裸 pcall 吞錯會讓路線
    -- 靜默消失且每幀重試失敗熱路徑，三 review lanes 一致指認）
    if allowed and Core.drawNavRoute then
        local navOk, navErr = pcall(Core.drawNavRoute, inner)
        if not navOk and not inner._minidoracatNavRouteErrLogged then
            inner._minidoracatNavRouteErrLogged = true
            log("nav route draw failed: " .. tostring(navErr))
        end
    end
    local mapAPI = inner.mapAPI
    local playerObj = getSpecificPlayer(pn)
    -- 陣營分享來的：只畫「給這位玩家」的桶（青旗＋名字＋距離）；getUsername
    -- 原版用例 ISScoreboard.lua:108。已收到的目標仍受目前 AllowNavShare 閘門
    -- 即時控制（navGetShared 同源）
    local bucket = allowed and Core.navGetShared and Core.navGetShared(pn) or nil
    if bucket and playerObj then
        for author, t in pairs(bucket) do
            local sdx, sdy = t.x - playerObj:getX(), t.y - playerObj:getY()
            local cr, cg, cb = Core.navShareColor(author)
            drawNavIndicator(inner, mapAPI:worldToUIX(t.x, t.y), mapAPI:worldToUIY(t.x, t.y),
                cr, cg, cb, author, math.floor(math.sqrt(sdx * sdx + sdy * sdy) + 0.5))
        end
    end
    -- 搜尋落點 ping（本體在 _Search.lua 掛 Core.drawSearchPing——主 chunk locvar
    -- 已頂 Kahlua 200 上限（LexState actvar[200]），主檔不得再增頂層 local；
    -- 動態查同 :3924 Core.drawNavRoute 慣例）。無導航目標時也要畫，須在下行早退前
    if Core.drawSearchPing then Core.drawSearchPing(inner, mapAPI) end
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
    if not allowed then return end -- 被 gate 擋：狀態已收尾，只略過自身旗標繪製
    drawNavIndicator(inner, mapAPI:worldToUIX(t.x, t.y), mapAPI:worldToUIY(t.x, t.y),
        1.0, 0.85, 0.2, nil, dist) -- 自己＝金旗＋距離
end
-- test:nav-draw:end

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

-- 管理員檢視常駐標記（左上角琥珀膠囊）：只要該玩家的戰術或隱私旁路正在生效
-- 就一直畫——管理員必須「看得出自己看到的不是普通玩家看到的」，否則會把旁路
-- 結果當成一般玩家可見資訊回報。零旁路＝首行即返回（普通玩家零成本）。
-- 文字與寬度以元件為單位 memo（同座標列 MISC-3 快取策略）：文字是常數字串，
-- 只在語系/字型倍率變動後首幀重量測，逐幀零配置、零跨界量測。
-- 皮膚（Core.Skin＝家族 UI 框架 adapter，載入序在本檔之後故動態查）缺席時退回
-- 原生直角 drawRect（同設定視窗 prerender 的退回紅線）
-- test:admin-view-marker:start
local function drawAdminMarkerSkin(Skin, inner, w, h)
    Skin.fill(inner, 6, 6, w + 12, h + 6, Skin.COLORS.BG_PANEL)
    Skin.border(inner, 6, 6, w + 12, h + 6, Skin.COLORS.ACCENT_AMBER)
end

local function drawAdminViewMarker(inner)
    if not Policy then return end
    local pn = inner.playerNum or 0
    if not (Policy.tacticalActive(pn) or Policy.privacyActive(pn)) then return end
    local mk = inner._minidoracatAdminMark
    local txt = getText("UI_MinidoracatMiniMap_AdminViewMarker")
    if not mk then
        mk = {}
        inner._minidoracatAdminMark = mk
    end
    if mk.txt ~= txt then
        -- 尺寸先在 pcall 內完整量完、驗型，再提交 cache。跨 Lua/Java bridge
        -- 若拋錯或回 nil，仍以保守尺寸畫出安全標記；不可先寫 txt 讓半成品
        -- cache 永久卡住、旁路生效卻沒有 ADMIN VIEW 提示。
        local ok, w, h = pcall(function()
            local tm = getTextManager()
            return tm:MeasureStringX(UIFont.Small, txt), tm:getFontHeight(UIFont.Small)
        end)
        if not ok or type(w) ~= "number" or w ~= w or w < 0
                or type(h) ~= "number" or h ~= h or h <= 0 then
            if not inner._minidoracatAdminMarkMeasureErrLogged then
                inner._minidoracatAdminMarkMeasureErrLogged = true
                log("admin view marker measurement failed, using fixed metrics: "
                    .. tostring(ok and "invalid metrics" or w))
            end
            w = math.min(240, math.max(60, type(txt) == "string" and #txt * 6 or 80))
            h = 14
        end
        mk.w, mk.h, mk.txt = w, h, txt
    end
    local Skin = Core.Skin
    local painted = false
    if Skin then
        local ok, err = pcall(drawAdminMarkerSkin, Skin, inner, mk.w, mk.h)
        painted = ok
        if not ok and not inner._minidoracatAdminMarkSkinErrLogged then
            inner._minidoracatAdminMarkSkinErrLogged = true
            log("admin view marker skin failed, using rectangular fallback: " .. tostring(err))
        end
    end
    if not painted then
        inner:drawRect(6, 6, mk.w + 12, mk.h + 6, 0.72, 0, 0, 0)
        inner:drawRectBorder(6, 6, mk.w + 12, mk.h + 6, 1, 1, 0.85, 0.4)
    end
    inner:drawText(mk.txt, 12, 9, 1, 0.85, 0.4, 1, UIFont.Small)
end
-- test:admin-view-marker:end

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
        context:addOption(getText("UI_MinidoracatMiniMap_SearchMenu"), self,
            self.onMinidoracatSearch)
        if navTargets[pn] then
            context:addOption(getText("UI_MinidoracatMiniMap_ClearTarget"), self,
                self.onMinidoracatClearTarget)
            if isClient() and Faction and Faction.getPlayerFaction(playerObj)
                and Core.navShareAllowed() then
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
        if sandboxGate("AllowZombieIntensity", true, self.playerNum or 0) == false then
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
        Core.drawZonePass(self, "drawZoneFill", "_minidoracatZoneFillErrLogged")
        pcall(drawSafehouses, self) -- pcall 防清單併發增刪（同殭屍取樣的防禦策略）
        pcall(drawMapBounds, self)
        Core.drawZonePass(self, "drawZoneLines", "_minidoracatZoneLineErrLogged") -- 與 MapBounds 同層
        Core.drawZonePass(self, "drawZoneIcons", "_minidoracatZoneIconErrLogged") -- POI 圖標，同層
        pcall(drawPlayerCoords, self) -- 在導航目標之前畫（距離標籤蓋膠囊，見函式註解）
        pcall(drawNavTargets, self)
        -- 動物圖標（畫在殭屍點位之下：殭屍小點蓋大圖標可辨）。持久錯誤首次記 log
        -- 免全靜默（API 漂移/第三方動物資料異常可診斷；既有三個 pcall 沿舊慣例不動）
        local adOk, adErr = pcall(Core.drawAnimalDots, self, "AnimalWild", "AnimalLivestock", "VehicleDots")
        if not adOk and not self._minidoracatADotsErrLogged then
            self._minidoracatADotsErrLogged = true
            log("animal icons draw failed: " .. tostring(adErr))
        end
        -- 自由查看「已離開跟隨」提示（導航軟體回中提示的同款模式）：拖離後地圖
        -- 底部浮出琥珀色膠囊＋定位圖示同步高亮——點地圖本就會回中（onMouseUp
        -- 清旗標），這裡只補視覺提醒，回中即消失（實測回饋：玩家不知道為何地圖不跟人）
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
        if cBtn then -- 定位 icon 琥珀高亮＝次要提示；還原值同皮膚化基準（skinBtn
            -- 0.55 a0.35，見 installMinidoracatButtons）；琥珀時 a 拉滿保持醒目
            cBtn.borderColor.r = flOn and 1 or 0.55
            cBtn.borderColor.g = flOn and 0.85 or 0.55
            cBtn.borderColor.b = flOn and 0.4 or 0.55
            cBtn.borderColor.a = flOn and 1 or 0.35
        end
        if Core.drawZombieDotsOn then -- 繪製本體在 _Dots.lua（世界地圖用 WMZombieDots）
            Core.drawZombieDotsOn(self, "ZombieDots")
        end
        -- 管理員檢視標記畫在全部加繪之上（最後呼叫）：它是「你正在看旁路資料」
        -- 的提示，不得被點雲/圖標蓋掉；失敗 log-once 且下一幀重試
        local adminOk, adminErr = pcall(drawAdminViewMarker, self)
        if not adminOk and not self._minidoracatAdminMarkErrLogged then
            self._minidoracatAdminMarkErrLogged = true
            log("admin view marker draw failed: " .. tostring(adminErr))
        end
    end
end

--------------------------------------------------------------------------------
-- 邊緣拖曳縮放 + HUD 視覺微調
-- 事件路由（UIElement.java:1015 onMouseDown：1047-1057 先讓子元件消化、
-- 沒人消化才輪到自己的 Lua handler 1096）：RESIZE_EDGE=8 熱區與卡片外框
-- CHROME_BORDER=8 同寬，左右/上下熱區大多落在 outer 自己的邊框環上；但
-- adorned（滑鼠在圖上，正是會拖曳的時刻）時上緣是 titleBar、下緣熱區
-- 與 bottomPanel 相接，inner 亦可能吃到深入的角落熱區——三個 class 的
-- 滑鼠事件仍須全部 hook（歷史前提「2px 環」時代如此，8px 後同樣成立）。
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

-- 外框邊色每幀調色（穿透琥珀＝主提示；hover/拖曳亮階）：抽成單一實作供
-- 兩處呼叫——class 層 prerender wrap（兜底：未走 installMinidoracatButtons
-- 的實例）與皮膚化實例 prerender（會遮蔽 class wrap，見 install 尾端註解）。
-- 皮膚 border 直讀 borderColor，調色先於繪製即生效
chromeTintBorder = function(outer)
    if getBoolOption("GhostMode", false) then
        -- 穿透中：琥珀邊框＝「看得到摸不到」主提示（mod 琥珀慣例），不做 hover 變化
        outer.borderColor.r, outer.borderColor.g, outer.borderColor.b = 1, 0.85, 0.4
    else
        local hover = outer:isMouseOver() or (resizeState ~= nil and resizeState.outer == outer)
        local v = hover and 0.55 or 0.4
        outer.borderColor.r, outer.borderColor.g, outer.borderColor.b = v, v, v
    end
end

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
        chromeTintBorder(self)
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
            log("minimap creation failed: " .. tostring(err))
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
-- 管理員檢視（雙層政策的客戶端讀取面）：Policy 為 nil＝舊版共用檔／載入失敗，
-- 模組檔沿用「Core.policy 為 nil ⇒ 沒有管理員檢視」的 fail-closed 判斷
Core.policy = Policy
Core.drawAdminViewMarker = drawAdminViewMarker -- _WorldMapNav.lua：世界地圖側同款標記
local zoneCatErrLogged = {} -- zoneExternalCategories 的 provider 失敗 log-once（依 owner）
-- 統一視窗「自訂區域」區塊用：收集外部 provider 當前 zone 的 distinct category
-- （排序穩定；無 category 的 zone 不列——類別是伺服器 zones.json 選配欄位）。
-- 視窗開啟時才呼叫，pcall 防外部 provider 拋錯（失敗依 owner log-once，
-- 不得靜默呈現成「沒有分類」——codex review）。
-- 可編碼過濾：類別是自由字串，含逗號或恰為 CSV sentinel（-/nil）者無法在
-- ZoneCategoryFilter 停用清單可逆表示——停用「a,b」會誤傷類別 a 與 b。判定
-- 用單鍵 round-trip（unifiedCsvSet(c)[c]），對 parser 語意零假設；不可編碼者
-- 不進清單＝永遠顯示、永不落 CSV（fail-visible）
-- test:zone-categories:start
Core.zoneExternalCategories = function()
    local seen, list = {}, {}
    for i = 1, #registeredZoneProviders do
        local p = registeredZoneProviders[i]
        if not p.internal then
            local ok, zones = pcall(p.fn)
            if not ok then
                if not zoneCatErrLogged[p.owner or "?"] then
                    zoneCatErrLogged[p.owner or "?"] = true
                    log("zone category scan failed (" .. tostring(p.owner) .. "): " .. tostring(zones))
                end
            elseif type(zones) == "table" then
                for zi = 1, #zones do
                    local z = zones[zi]
                    local c = z and z.category
                    if type(c) == "string" and c ~= "" and not seen[c]
                        and unifiedCsvSet(c)[c] == true then
                        seen[c] = true
                        -- 插入排序取代 table.sort（家規：Kahlua 禁用，見 verify_mod）；
                        -- 類別數極小（伺服器自訂、通常個位數），O(n²) 無妨
                        local pos = #list + 1
                        while pos > 1 and list[pos - 1] > c do
                            list[pos] = list[pos - 1]
                            pos = pos - 1
                        end
                        list[pos] = c
                    end
                end
            end
        end
    end
    return list
end
-- test:zone-categories:end
Core.ADOTS_COLOR_ITEMS = ADOTS_COLOR_ITEMS
Core.ADOTS_SPECIES_UI = ADOTS_SPECIES_UI
Core.ADOTS_VEHCAT_UI = ADOTS_VEHCAT_UI
Core.ADOTS_ART = ADOTS_ART
Core.adotsTexture = adotsTexture
Core.ADOTS_FALLBACK_SYM = ADOTS_FALLBACK_SYM -- _Dots.lua：未知物種腳印備援
Core.deriveAffine = deriveAffine -- _Dots.lua：仿射投影快取（zone/POI/點雲共用單一實作）
Core.registeredPacks = registeredPacks
Core.registeredZoneProviders = registeredZoneProviders
Core.hasExternalZoneProvider = hasExternalZoneProvider
Core.registeredZoneActions = registeredZoneActions
Core.togglePlayerMiniMap = togglePlayerMiniMap
Core.debugWarn = debugWarn
Core.applyChromeOpacity = applyChromeOpacity -- _Ghost.lua 切換穿透時重套外框透明度
Core.cancelResize = cancelResize -- _Ghost.lua 進穿透時取消進行中的邊緣縮放
Core.clipSegment = clipSegment -- _NavRoute.lua：路線裁剪（共用零配置 Liang-Barsky 單一實作）
Core.drawClippedEdge = drawClippedEdge -- _Zones.lua：zone 框線裁切畫線（共用 Liang-Barsky 單一實作）
Core.drawNavTargets = drawNavTargets -- _WorldMapNav.lua：世界地圖側導航旗標/箭頭（共用繪製）
Core.getLoadedMapDirs = getLoadedMapDirs -- _NavRoute.lua：cell 勝出閘門的地圖優先序來源
Core.visibleWorldAABB = visibleWorldAABB -- _NavRoute.lua：路線繪製的世界視窗剔除（共用單一實作）
Core.drawPlayerCoords = drawPlayerCoords -- _WorldMapNav.lua：世界地圖側座標列（共用繪製）
Core.copyCoordsText = copyCoordsText -- _WorldMapNav.lua：右鍵複製座標（共用剪貼簿＋琥珀回饋）
Core.ready = true -- 模組檔載入閘門：最後設定＝主檔完整走完才放行

log("loaded (hooks: ISWorldMap:initDataAndStyle + ISMiniMap.InitPlayer + button bar + gear panel + hotkey + mod options + zombie dots + edge zoom)")
