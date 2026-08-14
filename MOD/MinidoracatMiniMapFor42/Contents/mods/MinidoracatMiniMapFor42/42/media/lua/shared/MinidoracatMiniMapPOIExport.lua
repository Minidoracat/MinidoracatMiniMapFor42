-- MinidoracatMiniMapPOIExport.lua — 資源點區塊 JSON 匯出（外部工具契約）
-- 啟動時把 MinidoracatMiniMapPOIData（烘焙資料，shared 目錄、client/server 都載）
-- 序列化成 Zomboid/Lua/MinidoracatMiniMap/poi_blocks.json，給外部程式（如
-- MinidoracatBuildingResetFor42 重置工具）讀「地圖上實際顯示的資源點區塊」——
-- 與 Zones addon 的 zones.json 同在 Zomboid/Lua 根，工具端一個根目錄讀兩份。
--
-- 檔案格式 v1（一條目一行；條目間逗號在行首）：
--   {"v":1,"count":N,"categories":{
--   "<cat>":[{"b":[x,y,w,h],"r":[[x,y,w,h],...]}
--   ,{...}
--   ],"<cat2>":[...
--   ]}}
--   · 座標＝世界 square，x/y 左上角、w/h 尺寸，涵蓋 tiles [x, x+w-1]；
--     B42 chunk 換算 wx = floor(tileX/8)（chunk = 8×8 tiles，存檔 map/<wx>/<wy>.bin，
--     見 .omc/research/pz-b42-runtime-chunk-reset.md）
--   · b＝整棟建築外框（整棟重置的刪 chunk 依據）；r＝主分類觸發房矩形（面積
--     大→小，r[1] 為圖標錨點）——語意同 MinidoracatMiniMapPOIData 檔頭的 b/r，
--     b 缺席（測試 fixture 契約）時省略該欄
--   · categories key 按字母序（POIData 本身按 cat 排序）、條目順序與 POIData
--     相同——輸入不變則輸出逐 byte 相同
--
-- 寫入時機：單機＝OnGameStart（isClient()==false）、專用/合作伺服器＝
-- OnServerStarted（server-only event，vanilla 前例 shared/Util/LuaNet.lua:288 同樣
-- 從 shared 檔掛）；MP 純 client 不寫（檔案只對跑重置工具的主機有意義）。每次
-- 啟動整檔覆寫——資料隨 MOD 版本走，檔案永遠反映當前安裝版本；工具端請容忍
-- 檔案不存在（MOD 更新後尚未開過一次遊戲/伺服器）。
--
-- getFileWriter（LuaManager；家族用例 _Migrate.lua:80）副檔名白名單 42.20.1 起
-- 含 .json（ALLOWED_FILE_EXTENSIONS 演進見 Zones addon MinidoracatZonesShared.lua
-- 檔頭）；相對子路徑會自動建目錄（Zones zones.json 同款寫法，實機驗證）。
-- 失敗（回 null）僅 log 略過，下次啟動重試。
-- 先組完整字串再開檔（Zones 教訓：組字失敗不留半寫檔案）。

-- test:poi-export:start
-- 純字串組裝、無 PZ API——離線測試 scripts/test_poi_export.lua 抽本區段。
-- 迭代一律用 count/rn（Kahlua # 不可信）；數字經 .. 串接走 Kahlua
-- numberToString（KahluaUtil.java:180，整數值 <1e14 印整數不帶 .0）。
local function buildPoiBlocksJson(data)
    local lines = { '{"v":1,"count":' .. data.count .. ',"categories":{' }
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
        lines[ln] = table.concat(parts)
    end
    ln = ln + 1
    lines[ln] = (curCat ~= nil) and ']}}' or '}}'
    return table.concat(lines, "\n")
end
-- test:poi-export:end

local function exportPoiBlocks()
    local data = MinidoracatMiniMapPOIData
    if type(data) ~= "table" or type(data.count) ~= "number" or data.count < 1 then
        print("[MinidoracatMiniMap] poi_blocks export skipped (no POI data)")
        return
    end
    local text = buildPoiBlocksJson(data)
    local writer = getFileWriter("MinidoracatMiniMap/poi_blocks.json", true, false)
    if not writer then
        print("[MinidoracatMiniMap] poi_blocks export skipped (getFileWriter unavailable)")
        return
    end
    writer:write(text)
    writer:close()
    print("[MinidoracatMiniMap] poi_blocks.json exported (" .. data.count .. " buildings)")
end

Events.OnServerStarted.Add(exportPoiBlocks)
Events.OnGameStart.Add(function()
    if not isClient() then exportPoiBlocks() end
end)
