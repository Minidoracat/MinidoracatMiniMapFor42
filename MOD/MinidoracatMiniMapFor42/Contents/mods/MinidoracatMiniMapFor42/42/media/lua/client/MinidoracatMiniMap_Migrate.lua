-- MinidoracatMiniMap_Migrate.lua
-- 本檔範圍：兩個一次性遷移（自主檔 MinidoracatMiniMap.lua 拆出，內容原樣搬遷）——
-- 快捷鍵舊預設 HOME→/（marker 檔冪等）＋大小 combobox→滑條（0.9.0，.selected 訊號冪等）。
-- 載入順序假設：PZ 依字母序載入同目錄 lua，'.'(0x2E) < '_'(0x5F) → 主檔必先載入並
-- 建好 MinidoracatMiniMapCore 命名空間；本檔載入期只讀取其「一次性賦值」的穩定引用
-- 並定義函式/掛事件，跨檔「函式呼叫」一律發生在事件/呼叫時。
-- 拆檔緣由：Kahlua 編譯器每個函式原型（含每檔主 chunk）locvar 上限 200
-- （LexState.new_localvar 固定陣列，超過＝整檔拒載），主檔已貼頂——拆檔＝獨立額度。
local Core = MinidoracatMiniMapCore
-- ready＝主檔完整走完（版本檢查通過）才為真：拆分前本節位於主檔版本檢查之後，
-- 版本不符時整節不存在——此閘門維持同義行為
if not (Core and Core.ready) then return end

local modOptions = Core.modOptions -- 無 PZAPI（版本過舊）時為 nil，migrateSliderOptions 首行防呆沿用
-- log/getComboIndex 以裸名供 test:* 區段離線測試 stub 注入（scripts/test_key_migration.lua）：
-- log 與主檔同款一行實作（免載入期跨檔耦合）、getComboIndex 呼叫時分派主檔本體
local function log(msg) print("[MinidoracatMiniMap] " .. tostring(msg)) end
local function getComboIndex(id, default) return Core.getComboIndex(id, default) end

-- 舊三檔 combobox 的像素映射（0.9.0 起渲染改讀滑條，這些換算表只剩遷移用——
-- 隨遷移程式碼一併搬入本檔，主檔不再持有）
local ZDOTS_SIZES = { 2, 3, 4 }         -- 殭屍點 小/中（預設）/大（px）
local ADOTS_SIZES_SYM = { 12, 16, 20 }  -- 動物符號風格 小/中（預設）/大（px）
local ADOTS_SIZES_ITEM = { 16, 20, 26 } -- 動物物品彩圖風格 小/中（預設）/大（px）

-- ═══ 一次性快捷鍵遷移：舊預設 HOME → / ═══
-- 改預設救不了既有安裝：MainOptions.loadKeys 先註冊 Lua 預設、再以 keysB42.ini
-- 既存值覆寫（MainOptions.lua:3601），ini 永遠贏。首次進遊戲時若綁定仍是
-- 「無修飾鍵的 HOME」（＝沿用舊預設，非玩家刻意設定）則遷移為 /，並寫 marker 檔
-- 記錄已處理——玩家事後刻意改回 HOME 不再干預。
-- 寫回缺一不可（saveKeys 以 MainOptions.keyText 為真相來源整檔重寫並回填 Core，
-- 只改 Core 會在玩家下次按選項套用時被 keyText 沖回）：keyText 條目 → saveKeys。
-- test:key-migration:start
local function migrateToggleKeyOnce()
    -- marker 檔名放函式內：主 chunk 貼 Kahlua 200 locvar 上限，省頂層宣告
    local MIGRATE_MARKER = "MinidoracatMiniMap_keyMigratedV1.txt"
    local reader = getFileReader(MIGRATE_MARKER, false)
    if reader then
        reader:close()
        return -- 已處理過
    end
    -- resolved＝狀態已判定（非 HOME／找到條目並處理完）。Core 是 HOME 但 keyText
    -- 未就緒或條目缺失＝未解析：不寫 marker、下次進遊戲重試——否則遷移被永久跳過
    local resolved = false
    local ok, err = pcall(function()
        if getCore():getKey("MinidoracatMiniMap_Toggle") ~= Keyboard.KEY_HOME then
            resolved = true -- 已是 K 或玩家自改鍵，無事可做
            return
        end
        if not (MainOptions and type(MainOptions.keyText) == "table" and MainOptions.saveKeys) then
            return
        end
        for _, v in ipairs(MainOptions.keyText) do
            -- 跳過分區標籤列（v.value = "[...]"，同原版 keyPressHandler 慣例）
            if not v.value and v.txt and v.txt:getName() == "MinidoracatMiniMap_Toggle" then
                if v.keyCode == Keyboard.KEY_HOME and not (v.shift or v.ctrl or v.alt) then
                    v.keyCode = Keyboard.KEY_SLASH
                    -- 同步選項畫面按鈕標題（同原版 keyPressHandler 寫法）
                    if v.btn and MainOptions.getKeyPrefix then
                        v.btn:setTitle(MainOptions.getKeyPrefix(v) .. getKeyName(Keyboard.KEY_SLASH))
                    end
                    -- saveKeys 內部 reinitKeyMaps 後逐條 writeKey→addKeyBinding
                    -- 回填 Core（MainOptions.lua:3733-3771），無需另呼叫 addKeyBinding
                    MainOptions.saveKeys()
                    log("hotkey auto-migrated HOME -> / (old default clashes with an engine render-debug key under -debug)")
                end
                resolved = true -- 找到條目並完成判定（已遷移，或帶修飾鍵＝刻意設定不動）
                break
            end
        end
    end)
    if not ok then
        log("hotkey migration failed (will retry next game start): " .. tostring(err))
        return -- 不寫 marker，保留重試機會
    end
    if not resolved then
        log("hotkey migration unresolved (options screen not ready or entry missing), will retry next game start")
        return
    end
    local writer = getFileWriter(MIGRATE_MARKER, true, false)
    if writer then
        writer:write("v1")
        writer:close()
    end
end
-- test:key-migration:end
Events.OnGameStart.Add(migrateToggleKeyOnce)

-- ═══ 一次性選項遷移：大小 combobox → 滑條（0.9.0） ═══
-- PZAPI.ModOptions:load()（主選單建立時，MainOptions.lua:2823）讀到舊 combobox 行
-- 會把索引寫進同 id 新 slider 選項的 .selected（load 依「存檔行舊型別」分派，
-- ModOptions.lua:320；slider 自身永不寫該欄）——以此為訊號把檔位換算成像素值。
-- save 後該行改寫為 slider 型別、.selected 不再出現＝天然冪等，免 marker 檔。
-- test:slider-migration:start
local function migrateSliderOptions()
    if not modOptions then return end
    local changed = false
    -- 讀走 .selected（無論映射成敗都清掉並標記落盤；成功才寫值）。
    -- 消耗訊號即須 save：以 slider 型別重寫該行——否則超界舊 combobox 行
    -- 殘留 ini、每次啟動重新載入（codex review 抓出）
    local function takeOldIndex(id)
        local opt = modOptions:getOption(id)
        if not (opt and type(opt.selected) == "number") then return nil, opt end
        local idx = opt.selected
        opt.selected = nil
        changed = true
        return idx, opt
    end
    local function conv(id, map)
        local idx, opt = takeOldIndex(id)
        if idx and opt and map[idx] then
            opt:setValue(map[idx])
            changed = true
        end
        return idx
    end
    conv("ZombieDotSize", ZDOTS_SIZES)
    -- 動物：舊值依「當時的風格」選映射表（物品風格整表較大——0.9.0 前的行為）
    local animalMap = getComboIndex("AnimalIconStyle", 1) == 2 and ADOTS_SIZES_ITEM or ADOTS_SIZES_SYM
    local oldAnimalIdx = conv("AnimalIconSize", animalMap)
    -- 載具：0.9.0 前與動物共用一顆且恆用 SYM 表——以舊動物索引播種新獨立選項
    if oldAnimalIdx and ADOTS_SIZES_SYM[oldAnimalIdx] then
        local vOpt = modOptions:getOption("VehicleIconSize")
        if vOpt then
            vOpt:setValue(ADOTS_SIZES_SYM[oldAnimalIdx])
            changed = true
        end
    end
    if changed then
        PZAPI.ModOptions:save()
        log("icon size options converted from old presets to slider values")
    end
end
-- test:slider-migration:end
Events.OnMainMenuEnter.Add(migrateSliderOptions) -- load() 之後最早的穩定時機；冪等，重回選單重跑無害

-- ═══ 一次性強制開啟：圖片化地圖總開關（0.10.1） ═══
-- 0.10.0 的 getLoadedMapDirs 用了 PZ Kahlua 不存在的 next()（BaseLib 未註冊），
-- 掛載鏈全炸、圖片地圖退回原版樣式。故障期間部分玩家排查時把 MapImagery 關掉——
-- 修復後他們仍看原版、且不知道要開回來。比照快捷鍵遷移：一次性強制開回預設 true
-- ＋寫 marker；之後玩家再關掉即是刻意選擇，不再干預。
-- test:imagery-force:start
local function forceImageryOnOnce()
    if not modOptions then return end -- 無 PZAPI＝無此選項，無事可做（不寫 marker，重試便宜）
    local MARKER = "MinidoracatMiniMap_imageryForcedV1.txt"
    local reader = getFileReader(MARKER, false)
    if reader then
        reader:close()
        return -- 已處理過
    end
    local opt = modOptions:getOption("MapImagery")
    if not opt then return end -- 選項未註冊（不應發生）：不寫 marker、下次進選單重試
    if opt:getValue() ~= true then
        opt:setValue(true)
        PZAPI.ModOptions:save()
        log("one-time re-enable of map imagery (0.10.0 mount failure fix); turn it off in options if unwanted")
    end
    local writer = getFileWriter(MARKER, true, false)
    if writer then
        writer:write("v1")
        writer:close()
    end
end
-- test:imagery-force:end
Events.OnMainMenuEnter.Add(forceImageryOnOnce) -- 同 slider 遷移時機：load() 之後、值已就緒

-- ═══ 一次性預設翻轉：資源點區塊整棟範圍（0.14.2） ═══
-- 0.14.0/0.14.1 預設關；PZAPI save() 是整檔全寫（ModOptions.lua:259）——玩家改過
-- 任何選項就把沒碰過的 false 一併落檔、load 時存值優先於預設，只改註冊預設救不了
-- 既有安裝。存檔裡的 false 幾乎全是「沒動過」而非刻意選擇（選項上線僅一天），
-- 比照 MapImagery 前例一次性翻成新預設＋寫 marker；之後玩家再關掉即是刻意選擇，
-- 不再干預。marker 自本次起集中放 MOD 子資料夾（Lua/MinidoracatMiniMap/，與
-- poi_blocks.json 同處；getFileWriter 相對子路徑自動建目錄——POIExport 實機
-- 驗證）；既有兩個根目錄 marker 屬歷史產物、原地不動（搬遷需雙路徑相容碼，
-- 不值得為一次性檔案做）。
-- test:pwb-default:start
local function forceWholeBuildingOnOnce()
    if not modOptions then return end -- 無 PZAPI＝無此選項（不寫 marker，重試便宜）
    local MARKER = "MinidoracatMiniMap/wholeBuildingDefaultV1.txt"
    local reader = getFileReader(MARKER, false)
    if reader then
        reader:close()
        return -- 已處理過（存在即已處理——與下方驗證同一判準）
    end
    local opt = modOptions:getOption("PoiWholeBuilding")
    if not opt then return end -- 選項未註冊（不應發生）：不寫 marker、下次進選單重試
    -- 順序刻意與 imagery 前例相反：先寫 marker、讀回驗證落地，通過才翻值。
    -- 子資料夾 marker 是新失敗面，且 LuaFileWriter 走 PrintWriter 吞 IO 例外
    -- （pcall 接不到，讀回是唯一證據——POIExport 前例）；若翻值在先而 marker
    -- 沒落地，下次啟動會重翻、覆蓋玩家事後的刻意關閉——違反「取消後不再干預」
    -- 承諾（codex review 反例）。寧可漏翻（fail closed：本次不動、下次重試），
    -- 不可重複干預。驗證判準＝存在性，與上方「已處理過」判準一致：marker
    -- 存在（即使內容殘缺）下次必早退，翻值即安全。
    local writer = getFileWriter(MARKER, true, false)
    if writer then
        -- pcall 只防 Java wrapper 例外炸掉選單事件；IO 失敗本就不拋、靠下方讀回
        local wok = pcall(function()
            writer:write("v1")
            writer:close()
        end)
        if not wok then pcall(function() writer:close() end) end
    end
    local back = getFileReader(MARKER, false)
    if not back then
        log("whole-building default marker not persisted; skipping flip (will retry next session)")
        return
    end
    back:close()
    if opt:getValue() ~= true then
        opt:setValue(true)
        PZAPI.ModOptions:save()
        log("one-time apply of new default whole-building POI blocks (default on since 0.14.2); uncheck in options if you prefer per-room")
    end
end
-- test:pwb-default:end
Events.OnMainMenuEnter.Add(forceWholeBuildingOnOnce) -- 同上：load() 之後、值已就緒
