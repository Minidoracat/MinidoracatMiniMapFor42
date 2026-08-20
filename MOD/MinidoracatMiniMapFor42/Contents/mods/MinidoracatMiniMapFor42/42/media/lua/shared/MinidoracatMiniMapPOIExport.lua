-- MinidoracatMiniMapPOIExport.lua — 資源點區塊 JSON 匯出（外部工具契約）
-- 啟動時把 MinidoracatMiniMapPOIData（烘焙資料，shared 目錄、client/server 都載）
-- 序列化成 Zomboid/Lua/MinidoracatMiniMap/poi_blocks.json，給外部程式（如
-- MinidoracatBuildingResetFor42 重置工具）讀「地圖上實際顯示的資源點區塊」——
-- 與 Zones addon 的 zones.json 同在 Zomboid/Lua 根，工具端一個根目錄讀兩份。
--
-- 檔案格式 v1（一條目一行；條目間逗號在行首）：
--   {"v":1,"modversion":"<mod.info modversion>","count":N,"categories":{
--   "<cat>":[{"b":[x,y,w,h],"u":1,"r":[[x,y,w,h],...]}
--   （"u":1＝地下條目（B42 basement，主分類房的主樓層在地下）；選配欄、
--   僅地下時輸出——additive 擴充，消費端（pz-rewild）忽略未知鍵不受影響）
--   ,{...}
--   ],"<cat2>":[...
--   ]}}
--   · 座標＝世界 square，x/y 左上角、w/h 尺寸，涵蓋 tiles [x, x+w-1]；
--     B42 chunk 換算 wx = floor(tileX/8)（chunk = 8×8 tiles，存檔 map/<wx>/<wy>.bin，
--     見 .omc/research/pz-b42-runtime-chunk-reset.md）
--   · b＝整棟建築外框（整棟重置的刪 chunk 依據）；r＝主分類觸發房矩形（面積
--     大→小，r[1] 為圖標錨點）——語意同 MinidoracatMiniMapPOIData 檔頭的 b/r，
--     b 缺席（測試 fixture 契約）時省略該欄
--   · modversion＝寫檔當下安裝的 MOD 版本（取不到時 "unknown"）——新鮮度標記，
--     同版本內輸出 byte-identical、版本更新才變
--   · categories key 按字母序（POIData 本身按 cat 排序）、條目順序與 POIData
--     相同——輸入不變則輸出逐 byte 相同
--
-- ⚠ 外部工具端義務（座標會被拿去刪存檔 chunk，讀壞資料＝刪錯區域）：
--   1. 整檔嚴格 JSON 解析；解析失敗＝視同檔案不存在，中止操作（撕裂檔防護——
--      外層物件到 EOF 才閉合，任何截斷前綴都過不了嚴格解析；勿逐行流式取用）。
--   2. 各分類條目總數必須等於 count，不等＝中止。
--   3. 破壞性操作前驗 modversion 等於伺服器實際安裝的 MOD 版本（保底：檔案
--      mtime ≥ 伺服器本次啟動時間）——寫檔失敗時舊檔會殘留，靠這條擋陳舊座標。
--   4. 容忍檔案不存在（MOD 更新後尚未開過一次遊戲/伺服器）。
--
-- 寫入時機：單機＝OnGameStart（isClient()==false）、專用/合作伺服器＝
-- OnServerStarted（server-only event，vanilla 前例 shared/Util/LuaNet.lua:288 同樣
-- 從 shared 檔掛）；MP 純 client 不寫（檔案只對跑重置工具的主機有意義）。每次
-- 啟動整檔覆寫——資料隨 MOD 版本走。POI 資料缺失（安裝損壞）時寫 count=0 空文件
-- 中和舊檔，不留陳舊座標給重置工具。
--
-- getFileWriter（LuaManager；家族用例 _Migrate.lua:80）副檔名白名單 42.20.1 起
-- 含 .json（ALLOWED_FILE_EXTENSIONS 演進見 Zones addon MinidoracatZonesShared.lua
-- 檔頭）——本功能是主 MOD versionMin 升 42.20.1 的原因（codex review 抓到
-- 42.20.0 白名單無 json、宣告支援版本上功能必死；Zones addon 本就 42.20.1）。
-- 相對子路徑會自動建目錄（Zones zones.json 同款寫法，實機驗證）。
-- 失敗（回 null）僅大聲 log 略過，下次啟動重試。
-- 先組完整字串再開檔（Zones 教訓：組字失敗不留半寫檔案）。

-- test:poi-export:start
-- 純字串組裝、無 PZ API——離線測試 scripts/test_poi_export.lua 抽本區段。
-- 迭代一律用 count/rn（Kahlua # 不可信）；數字經 .. 串接走 Kahlua
-- numberToString（KahluaUtil.java:180，整數值 <1e14 印整數不帶 .0）。
-- modversion 白名單消毒（僅留字母數字 . -）：值進 JSON 字串字面值，杜絕引號/
-- 反斜線破壞結構（正常 mod.info 版本號不受影響）。cat 刻意不消毒——烘焙的
-- 手寫識別字（純小寫字母），字元集由煙霧測試的 %a+ 類別段數檢查鎖定。
local function buildPoiBlocksJson(data, modversion)
    local mv = "unknown"
    if type(modversion) == "string" and modversion ~= "" then
        mv = modversion:gsub("[^%w%.%-]", "")
        if mv == "" then mv = "unknown" end
    end
    local lines = { '{"v":1,"modversion":"' .. mv .. '","count":' .. data.count
        .. ',"categories":{' }
    local ln = 1
    local curCat = nil
    for i = 1, data.count do
        local e = data[i]
        local head
        if e.cat == curCat then
            head = ','
        elseif curCat == nil then
            head = '"' .. e.cat .. '":['
            curCat = e.cat
        else
            head = '],"' .. e.cat .. '":['
            curCat = e.cat
        end
        local parts = { head, '{' }
        local pn = 2
        local b = e.b
        if b then
            pn = pn + 1
            parts[pn] = '"b":[' .. b.x .. ',' .. b.y .. ',' .. b.w .. ',' .. b.h .. '],'
        end
        if e.u == 1 then
            pn = pn + 1
            parts[pn] = '"u":1,' -- 地下條目（basement；additive 選配欄——rewild 忽略未知鍵）
        end
        pn = pn + 1
        parts[pn] = '"r":['
        for j = 1, e.rn do
            local r = e.r[j]
            pn = pn + 1
            parts[pn] = ((j > 1) and ',' or '')
                .. '[' .. r.x .. ',' .. r.y .. ',' .. r.w .. ',' .. r.h .. ']'
        end
        pn = pn + 1
        parts[pn] = ']}'
        ln = ln + 1
        lines[ln] = table.concat(parts, "", 1, pn) -- 顯式界（家規：Kahlua 缺 4 參走 table.len＝隱性 # 依賴）
    end
    ln = ln + 1
    lines[ln] = (curCat ~= nil) and ']}}' or '}}'
    return table.concat(lines, "\n", 1, ln)
end
-- test:poi-export:end

local POI_BLOCKS_PATH = "MinidoracatMiniMap/poi_blocks.json"

-- 逐行讀回、以 "\n" 重組後與原文全等比對。getFileReader（家族用例 _Migrate.lua:37）
-- 無副檔名白名單；「不存在」與「IOException」都回 null（兩者這裡同屬驗證失敗）。
local function readBackMatches(path, text)
    local reader = getFileReader(path, false)
    if not reader then return false end
    local got = {}
    local gn = 0
    local line = reader:readLine()
    while line ~= nil do
        gn = gn + 1
        got[gn] = line
        line = reader:readLine()
    end
    reader:close()
    return table.concat(got, "\n") == text
end

local function exportPoiBlocks()
    -- 版本取用失敗（API 缺席/例外）降級 "unknown"，不擋匯出
    local okMv, info = pcall(getModInfoByID, "MinidoracatMiniMapFor42")
    local mv = nil
    if okMv and info then
        local okV, v = pcall(function() return info:getModVersion() end)
        if okV then mv = v end
    end
    local data = MinidoracatMiniMapPOIData
    local text
    local exported = 0
    if type(data) == "table" and type(data.count) == "number" and data.count >= 1 then
        -- pcall：烘焙資料異常（rn 超界等）不炸 boot 事件——落到下方空文件路徑
        local okB, built = pcall(buildPoiBlocksJson, data, mv)
        if okB then
            text = built
            exported = data.count
        else
            print("[MinidoracatMiniMap] poi_blocks export build FAILED (" .. tostring(built) .. ")")
        end
    end
    if not text then
        -- 資料缺失/組字失敗＝安裝損壞：寫 count=0 空文件「中和」舊檔——重置工具
        -- 讀到空集就不動作；留著舊座標反而會被拿去刪錯區域（silent-failure review
        -- 發現）。空輸入的 builder 無失敗路徑，不需再包 pcall
        text = buildPoiBlocksJson({ count = 0 }, mv)
        print("[MinidoracatMiniMap] poi_blocks export: no usable POI data, writing EMPTY document to neutralize any stale file")
    end
    local writer = getFileWriter(POI_BLOCKS_PATH, true, false)
    if not writer then
        print("[MinidoracatMiniMap] poi_blocks export FAILED (getFileWriter unavailable) -- existing poi_blocks.json is now STALE; external tools must verify modversion before use")
        return
    end
    -- pcall 只為保住後續讀回驗證（Java wrapper 例外不炸 boot 事件、不漏 close）
    local okW = pcall(function()
        writer:write(text)
        writer:close()
    end)
    if not okW then
        pcall(function() writer:close() end)
    end
    -- 讀回驗證（Zones 防追認前例）：LuaFileWriter.write/close 走 PrintWriter
    -- （LuaManager.java:12751-12770）——IO 失敗不拋例外（PrintWriter 內吞 trouble
    -- flag），pcall 接不到磁碟錯誤；逐行讀回比對是唯一可靠的完整性證據，驗證
    -- 通過才記成功。readLine 剝行尾，以 "\n" 重組與原文比對（builder 只用 \n）。
    if readBackMatches(POI_BLOCKS_PATH, text) then
        print("[MinidoracatMiniMap] poi_blocks.json exported (" .. exported
            .. " buildings, modversion " .. tostring(mv or "unknown") .. ")")
    else
        print("[MinidoracatMiniMap] poi_blocks export verify FAILED -- poi_blocks.json may be TORN/STALE; external tools must strict-parse, verify count and modversion before use")
    end
end

Events.OnServerStarted.Add(exportPoiBlocks)
Events.OnGameStart.Add(function()
    if not isClient() then exportPoiBlocks() end
end)
