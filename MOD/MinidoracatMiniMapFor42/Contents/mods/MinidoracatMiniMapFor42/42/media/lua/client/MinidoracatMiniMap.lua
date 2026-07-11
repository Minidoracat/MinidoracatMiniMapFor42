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
        local minimap = originalInitPlayer(playerNum)
        if minimap and minimap.inner and minimap.inner.mapAPI then
            local ok, err = pcall(applyMiniMapPyramids, minimap.inner)
            if not ok then
                log("小地圖初始化失敗: " .. tostring(err))
            end
        end
        return minimap
    end
end

log("已載入（hook ISWorldMap:initDataAndStyle + ISMiniMap.InitPlayer）")
