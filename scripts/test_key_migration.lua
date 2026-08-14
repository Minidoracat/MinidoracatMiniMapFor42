-- 一次性快捷鍵遷移（HOME→/）＋浮動圖標拖曳門檻回歸測試。
-- 仿 test_zone_render.lua 的 stub 風格：抽標記區段→補最小 stub→組裝可離線跑。
-- 主檔拆分後：遷移區段在 _Migrate.lua（arg[1]）、浮動圖標拖曳區段在 _FloatIcon.lua（arg[2]）。
-- 用法：lua scripts/test_key_migration.lua
local migratePath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Migrate.lua"
local floatIconPath = arg[2]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_FloatIcon.lua"

local function readSource(path)
    local file = assert(io.open(path, "rb"))
    local content = file:read("*a"):gsub("\r\n", "\n")
    file:close()
    return content
end
local source = readSource(migratePath)
local floatSource = readSource(floatIconPath)

local compile = loadstring or load

--------------------------------------------------------------------------------
-- 快捷鍵遷移：marker 判定（resolved 才寫）、修飾鍵不動、saveKeys 失敗不寫 marker
--------------------------------------------------------------------------------
local migBody = assert(source:match(
    "%-%- test:key%-migration:start\n(.-)\n%-%- test:key%-migration:end"),
    "找不到 key-migration 測試區段")
local migPrelude = [=[
local files = {}          -- 檔名 → 內容（getFileReader/getFileWriter 的記憶體後端）
local coreKey = 199       -- getCore():getKey 回傳值
local saveKeysCalls = 0
local saveKeysError = false
local logs = {}
local MainOptions         -- 各情境注入
local Keyboard = { KEY_HOME = 199, KEY_SLASH = 53 }
local function getCore()
    return { getKey = function(_, _) return coreKey end }
end
local function getFileReader(name, _)
    if files[name] then return { close = function() end } end
    return nil
end
local function getFileWriter(name, _, _)
    return {
        write = function(_, s) files[name] = s end,
        close = function() end,
    }
end
local function getKeyName(_) return "/" end
local function log(msg) logs[#logs + 1] = msg end
]=]
local migSuffix = [=[
return {
    run = migrateToggleKeyOnce,
    marker = "MinidoracatMiniMap_keyMigratedV1.txt", -- 檔名已移入函式內（Kahlua locvar 上限）
    setup = function(opts)
        files = opts.files or {}
        coreKey = opts.coreKey or 199
        saveKeysCalls = 0
        saveKeysError = opts.saveKeysError or false
        logs = {}
        MainOptions = opts.mainOptions
    end,
    state = function()
        return { files = files, saveKeysCalls = saveKeysCalls, logs = logs }
    end,
}
]=]
local migChunk, migErr = compile(migPrelude .. "\n" .. migBody .. "\n" .. migSuffix)
assert(migChunk, migErr)
local mig = migChunk()

-- 建構 keyText 條目／MainOptions 假件
local function mkEntry(name, keyCode, mods)
    mods = mods or {}
    local e = {
        txt = { getName = function(_) return name end },
        keyCode = keyCode,
        shift = mods.shift, ctrl = mods.ctrl, alt = mods.alt,
        titleSet = nil,
    }
    e.btn = { setTitle = function(_, t) e.titleSet = t end }
    return e
end
local function mkMainOptions(entries)
    return {
        keyText = entries,
        getKeyPrefix = function(v) return v.ctrl and "CTRL + " or "" end,
        saveKeys = function()
            error("saveKeys 失敗模擬", 0)
        end,
    }
end

-- A. marker 已存在 → 完全不動
mig.setup({ files = { [mig.marker] = "v1" }, coreKey = 199,
    mainOptions = { keyText = {}, saveKeys = function() error("不應被呼叫") end } })
mig.run()
assert(mig.state().saveKeysCalls == 0 and #mig.state().logs == 0, "A: marker 存在仍有動作")

-- B. 綁定已是 /（或自改鍵）→ 寫 marker、不碰 keyText
local entryB = mkEntry("MinidoracatMiniMap_Toggle", 53)
mig.setup({ coreKey = 53, mainOptions = { keyText = { entryB },
    getKeyPrefix = function() return "" end, saveKeys = function() error("不應被呼叫") end } })
mig.run()
assert(mig.state().files[mig.marker] == "v1", "B: 非 HOME 未寫 marker")
assert(entryB.keyCode == 53, "B: 不應改動 keyText")

-- C. HOME 無修飾鍵 → 遷移為 /、saveKeys 一次、寫 marker、更新按鈕標題
local entryC = mkEntry("MinidoracatMiniMap_Toggle", 199)
local savedC = 0
mig.setup({ coreKey = 199, mainOptions = {
    keyText = { { value = "[MinidoracatMiniMap]" }, entryC }, -- 首列＝分區標籤，須被跳過
    getKeyPrefix = function(v) return v.ctrl and "CTRL + " or "" end,
    saveKeys = function() savedC = savedC + 1 end,
} })
mig.run()
assert(entryC.keyCode == 53, "C: keyCode 未遷移為 /")
assert(savedC == 1, "C: saveKeys 呼叫次數應為 1，實得 " .. savedC)
assert(mig.state().files[mig.marker] == "v1", "C: 未寫 marker")
assert(entryC.titleSet == "/", "C: 按鈕標題未更新，實得 " .. tostring(entryC.titleSet))

-- D. HOME 帶 ctrl（玩家刻意設定）→ 不動、仍寫 marker（已解析）
local entryD = mkEntry("MinidoracatMiniMap_Toggle", 199, { ctrl = true })
mig.setup({ coreKey = 199, mainOptions = { keyText = { entryD },
    getKeyPrefix = function() return "" end, saveKeys = function() error("不應被呼叫") end } })
mig.run()
assert(entryD.keyCode == 199, "D: 帶修飾鍵仍被改動")
assert(mig.state().files[mig.marker] == "v1", "D: 已解析卻未寫 marker")

-- E. HOME 但條目缺失（keyText 空）→ 未解析：不寫 marker（下次重試）
mig.setup({ coreKey = 199, mainOptions = { keyText = {},
    getKeyPrefix = function() return "" end, saveKeys = function() end } })
mig.run()
assert(mig.state().files[mig.marker] == nil, "E: 條目缺失仍寫了 marker（遷移被永久跳過）")

-- F. HOME 但 MainOptions 未就緒 → 未解析：不寫 marker
mig.setup({ coreKey = 199, mainOptions = nil })
mig.run()
assert(mig.state().files[mig.marker] == nil, "F: MainOptions 缺失仍寫了 marker")

-- G. saveKeys 拋錯 → pcall 失敗：不寫 marker、keyCode 已改但下次可重試
local entryG = mkEntry("MinidoracatMiniMap_Toggle", 199)
mig.setup({ coreKey = 199, mainOptions = mkMainOptions({ entryG }) })
mig.run()
assert(mig.state().files[mig.marker] == nil, "G: saveKeys 失敗仍寫了 marker")

--------------------------------------------------------------------------------
-- 浮動圖標拖曳門檻：≦4px＝點擊 toggle、>4px＝拖曳存位置
--------------------------------------------------------------------------------
local dragBody = assert(floatSource:match(
    "%-%- test:float%-drag:start\n(.-)\n%s*%-%- test:float%-drag:end"),
    "找不到 float-drag 測試區段")
local dragPrelude = [=[
local FLOAT_DRAG_THRESHOLD = 4
local mouseX, mouseY = 0, 0
local savedPos, toggled, clamped
local function getMouseX() return mouseX end
local function getMouseY() return mouseY end
local function floatIconClamp(_) clamped = true end
local function floatIconSavePos(x, y) savedPos = { x = x, y = y } end
local function togglePlayerMiniMap() toggled = true end
]=]
local dragSuffix = [=[
return {
    move = moveIcon,
    release = releaseIcon,
    setMouse = function(x, y) mouseX, mouseY = x, y end,
    reset = function() savedPos, toggled, clamped = nil, nil, nil end,
    state = function() return { savedPos = savedPos, toggled = toggled, clamped = clamped } end,
}
]=]
local dragChunk, dragErr = compile(dragPrelude .. "\n" .. dragBody .. "\n" .. dragSuffix)
assert(dragChunk, dragErr)
local drag = dragChunk()

-- 假 icon 元件：欄位對齊 onMouseDown 設定的狀態
local function mkIcon(x, y)
    local o = { x = x, y = y }
    function o:getX() return self.x end
    function o:getY() return self.y end
    function o:setX(v) self.x = v end
    function o:setY(v) self.y = v end
    function o:setCapture(b) self.captured = b end
    return o
end
local function press(icon, mx, my)
    drag.setMouse(mx, my)
    icon._down = true
    icon._dragged = nil
    icon._downX, icon._downY = mx, my
    icon._origX, icon._origY = icon.x, icon.y
    icon.captured = true
end

-- H. 按下 → 位移 2px → 放開＝點擊：toggle、不存位置、位置不變
local iconH = mkIcon(100, 100)
drag.reset()
press(iconH, 50, 50)
drag.setMouse(52, 51)
assert(drag.move(iconH) == true, "H: move 應回 true")
assert(drag.release(iconH) == true, "H: release 應回 true")
assert(drag.state().toggled == true, "H: 點擊未觸發 toggle")
assert(drag.state().savedPos == nil, "H: 點擊不應存位置")
assert(iconH.x == 100 and iconH.y == 100, "H: 點擊不應移動圖標")
assert(iconH.captured == false, "H: 未釋放捕捉")

-- I. 按下 → 位移 10px → 放開＝拖曳：位置更新、clamp＋存檔、不 toggle
local iconI = mkIcon(100, 100)
drag.reset()
press(iconI, 50, 50)
drag.setMouse(60, 55)
drag.move(iconI)
drag.release(iconI)
assert(drag.state().toggled == nil, "I: 拖曳不應 toggle")
assert(iconI.x == 110 and iconI.y == 105, "I: 位置未依位移更新，實得 " .. iconI.x .. "," .. iconI.y)
assert(drag.state().clamped == true, "I: 放開未夾回螢幕")
assert(drag.state().savedPos and drag.state().savedPos.x == 110 and drag.state().savedPos.y == 105,
    "I: 位置未存檔")

-- J. 未按下的 move / release → 不動作
local iconJ = mkIcon(100, 100)
drag.reset()
assert(drag.move(iconJ) == false, "J: 未按下 move 應回 false")
assert(drag.release(iconJ) == false, "J: 未按下 release 應回 false")
assert(drag.state().toggled == nil and drag.state().savedPos == nil, "J: 未按下不應有副作用")

-- K. 跨過門檻後縮回原點仍屬拖曳（_dragged 黏著，不會誤判成點擊）
local iconK = mkIcon(100, 100)
drag.reset()
press(iconK, 50, 50)
drag.setMouse(60, 50)
drag.move(iconK)
drag.setMouse(50, 50) -- 拖回原點
drag.move(iconK)
drag.release(iconK)
assert(drag.state().toggled == nil, "K: 拖回原點被誤判為點擊")
assert(drag.state().savedPos ~= nil, "K: 拖曳結束未存位置")

--------------------------------------------------------------------------------
-- 選項遷移（combobox 檔位 → 滑條像素）：.selected 訊號、風格分表、載具播種
--------------------------------------------------------------------------------
local smBody = assert(source:match(
    "%-%- test:slider%-migration:start\n(.-)\n%-%- test:slider%-migration:end"),
    "找不到 slider-migration 測試區段")
local smPrelude = [=[
local ZDOTS_SIZES = { 2, 3, 4 }
local ADOTS_SIZES_SYM = { 12, 16, 20 }
local ADOTS_SIZES_ITEM = { 16, 20, 26 }
local saveCalls = 0
local logs = {}
local styleIdx = 1
local options = {}
local modOptions = { getOption = function(_, id) return options[id] end }
local function getComboIndex(id, default)
    if id == "AnimalIconStyle" then return styleIdx end
    return default
end
local PZAPI = { ModOptions = { save = function() saveCalls = saveCalls + 1 end } }
local function log(msg) logs[#logs + 1] = msg end
]=]
local smSuffix = [=[
return {
    run = migrateSliderOptions,
    setup = function(opts)
        options = opts.options or {}
        styleIdx = opts.styleIdx or 1
        saveCalls = 0
        logs = {}
    end,
    state = function() return { saveCalls = saveCalls, logs = logs } end,
}
]=]
local smChunk, smErr = compile(smPrelude .. "\n" .. smBody .. "\n" .. smSuffix)
assert(smChunk, smErr)
local sm = smChunk()

local function mkOpt(selected)
    local o = { selected = selected }
    o.setValue = function(self, v) self.value = v end
    return o
end

-- M1. 舊殭屍檔位 3（大）→ 4px、.selected 清除、save 一次
local z1 = mkOpt(3)
sm.setup({ options = { ZombieDotSize = z1 } })
sm.run()
assert(z1.value == 4, "M1: 檔位 3 未換算為 4px，實得 " .. tostring(z1.value))
assert(z1.selected == nil, "M1: .selected 未清除")
assert(sm.state().saveCalls == 1, "M1: save 應恰一次")

-- M2. 舊動物檔位 1＋符號風格 → 動物 12px；載具播種 12px
local a2, v2 = mkOpt(1), mkOpt(nil)
sm.setup({ options = { AnimalIconSize = a2, VehicleIconSize = v2 }, styleIdx = 1 })
sm.run()
assert(a2.value == 12, "M2: 動物未換算 12px，實得 " .. tostring(a2.value))
assert(v2.value == 12, "M2: 載具未播種 12px，實得 " .. tostring(v2.value))

-- M3. 舊動物檔位 2＋物品風格 → 動物走 ITEM 表 20px；載具恆走 SYM 表 16px
local a3, v3 = mkOpt(2), mkOpt(nil)
sm.setup({ options = { AnimalIconSize = a3, VehicleIconSize = v3 }, styleIdx = 2 })
sm.run()
assert(a3.value == 20, "M3: 物品風格未走 ITEM 表，實得 " .. tostring(a3.value))
assert(v3.value == 16, "M3: 載具未走 SYM 表，實得 " .. tostring(v3.value))

-- M4. 無 .selected（新安裝/已遷移）→ 零動作、不 save
local z4 = mkOpt(nil)
sm.setup({ options = { ZombieDotSize = z4, AnimalIconSize = mkOpt(nil), VehicleIconSize = mkOpt(nil) } })
sm.run()
assert(z4.value == nil and sm.state().saveCalls == 0, "M4: 無訊號仍有動作")

-- M5. 超界檔位（.selected=99，手改 ini）→ 清訊號、不寫值（保留滑條預設），
-- 但仍 save 一次：以 slider 型別重寫該行，否則舊 combobox 行殘留、每次啟動重載
local z5 = mkOpt(99)
sm.setup({ options = { ZombieDotSize = z5 } })
sm.run()
assert(z5.selected == nil, "M5: 超界 .selected 未清除")
assert(z5.value == nil, "M5: 超界檔位不應寫值")
assert(sm.state().saveCalls == 1, "M5: 消耗訊號後未落盤重寫")

--------------------------------------------------------------------------------
-- 一次性強制開啟圖片化（0.10.1）：marker 冪等、值 false 才寫、選項缺失重試
--------------------------------------------------------------------------------
local ifBody = assert(source:match(
    "%-%- test:imagery%-force:start\n(.-)\n%-%- test:imagery%-force:end"),
    "找不到 imagery-force 測試區段")
local ifPrelude = [=[
local files = {}
local saveCalls = 0
local logs = {}
local options = {}
local modOptions = { getOption = function(_, id) return options[id] end }
local PZAPI = { ModOptions = { save = function() saveCalls = saveCalls + 1 end } }
local function getFileReader(name, _)
    if files[name] then return { close = function() end } end
    return nil
end
local function getFileWriter(name, _, _)
    return {
        write = function(_, s) files[name] = s end,
        close = function() end,
    }
end
local function log(msg) logs[#logs + 1] = msg end
]=]
local ifSuffix = [=[
return {
    run = forceImageryOnOnce,
    marker = "MinidoracatMiniMap_imageryForcedV1.txt",
    setup = function(opts)
        files = opts.files or {}
        options = opts.options or {}
        saveCalls = 0
        logs = {}
        if opts.noModOptions then modOptions = nil end
    end,
    state = function() return { files = files, saveCalls = saveCalls, logs = logs } end,
}
]=]
local ifChunk, ifErr = compile(ifPrelude .. "\n" .. ifBody .. "\n" .. ifSuffix)
assert(ifChunk, ifErr)
local imf = ifChunk()

local function mkTick(v)
    return {
        value = v,
        getValue = function(self) return self.value end,
        setValue = function(self, nv) self.value = nv end,
    }
end

-- V1. marker 已存在 → 完全不動
local t1 = mkTick(false)
imf.setup({ files = { [imf.marker] = "v1" }, options = { MapImagery = t1 } })
imf.run()
assert(t1.value == false and imf.state().saveCalls == 0, "V1: marker 存在仍有動作")

-- V2. 值為 false → 強制 true、save 一次、log 一筆、寫 marker
local t2 = mkTick(false)
imf.setup({ options = { MapImagery = t2 } })
imf.run()
assert(t2.value == true, "V2: 未強制開啟")
assert(imf.state().saveCalls == 1, "V2: save 應恰一次，實得 " .. imf.state().saveCalls)
assert(#imf.state().logs == 1, "V2: 應 log 一筆")
assert(imf.state().files[imf.marker] == "v1", "V2: 未寫 marker")

-- V3. 值已是 true → 不寫值不 save，仍寫 marker（已解析）
local t3 = mkTick(true)
imf.setup({ options = { MapImagery = t3 } })
imf.run()
assert(imf.state().saveCalls == 0, "V3: 已開啟不應 save")
assert(imf.state().files[imf.marker] == "v1", "V3: 已解析卻未寫 marker")

-- V4. 選項缺失 → 不寫 marker（下次重試）、不炸
imf.setup({ options = {} })
imf.run()
assert(imf.state().files[imf.marker] == nil, "V4: 選項缺失仍寫了 marker（強制被永久跳過）")

-- V5. modOptions nil（無 PZAPI）→ 不寫 marker、不炸
imf.setup({ noModOptions = true })
imf.run()
assert(imf.state().files[imf.marker] == nil, "V5: 無 PZAPI 仍寫了 marker")

--------------------------------------------------------------------------------
-- 一次性預設翻轉：資源點區塊整棟範圍（0.14.2，同 imagery-force 五案例；
-- marker 集中放 MOD 子資料夾 Lua/MinidoracatMiniMap/）
--------------------------------------------------------------------------------
local pwbBody = assert(source:match(
    "%-%- test:pwb%-default:start\n(.-)\n%-%- test:pwb%-default:end"),
    "找不到 pwb-default 測試區段")
-- 自有 prelude（不共用 ifPrelude）：多 failWrite 開關模擬 marker 寫入失敗
-- ——marker-first＋讀回驗證的 fail-closed 語意（codex review 反例）需要此路徑
local pwbPrelude = [=[
local files = {}
local saveCalls = 0
local logs = {}
local options = {}
local failWrite = false
local modOptions = { getOption = function(_, id) return options[id] end }
local PZAPI = { ModOptions = { save = function() saveCalls = saveCalls + 1 end } }
local function getFileReader(name, _)
    if files[name] then return { close = function() end } end
    return nil
end
local function getFileWriter(name, _, _)
    if failWrite then return nil end
    return {
        write = function(_, s) files[name] = s end,
        close = function() end,
    }
end
local function log(msg) logs[#logs + 1] = msg end
]=]
local pwbSuffix = [=[
return {
    run = forceWholeBuildingOnOnce,
    marker = "MinidoracatMiniMap/wholeBuildingDefaultV1.txt",
    setup = function(opts)
        files = opts.files or {}
        options = opts.options or {}
        saveCalls = 0
        logs = {}
        failWrite = opts.failWrite or false
        -- 每次重建（而非只在 noModOptions 時設 nil）：nil 會殘留到下一個案例
        modOptions = opts.noModOptions and nil
            or { getOption = function(_, id) return options[id] end }
    end,
    state = function() return { files = files, saveCalls = saveCalls, logs = logs } end,
}
]=]
local pwbChunk, pwbErr = compile(pwbPrelude .. "\n" .. pwbBody .. "\n" .. pwbSuffix)
assert(pwbChunk, pwbErr)
local pwb = pwbChunk()

-- W1. marker 已存在 → 完全不動
local w1 = mkTick(false)
pwb.setup({ files = { [pwb.marker] = "v1" }, options = { PoiWholeBuilding = w1 } })
pwb.run()
assert(w1.value == false and pwb.state().saveCalls == 0, "W1: marker 存在仍有動作")

-- W2. 存值 false（0.14.x 舊預設落檔）→ 翻 true、save 一次、log 一筆、寫 marker
local w2 = mkTick(false)
pwb.setup({ options = { PoiWholeBuilding = w2 } })
pwb.run()
assert(w2.value == true, "W2: 未翻成新預設")
assert(pwb.state().saveCalls == 1, "W2: save 應恰一次，實得 " .. pwb.state().saveCalls)
assert(#pwb.state().logs == 1, "W2: 應 log 一筆")
assert(pwb.state().files[pwb.marker] == "v1", "W2: 未寫 marker（子資料夾路徑）")

-- W3. 值已是 true（玩家自己開過）→ 不寫值不 save，仍寫 marker
local w3 = mkTick(true)
pwb.setup({ options = { PoiWholeBuilding = w3 } })
pwb.run()
assert(pwb.state().saveCalls == 0, "W3: 已開啟不應 save")
assert(pwb.state().files[pwb.marker] == "v1", "W3: 已解析卻未寫 marker")

-- W4. 選項缺失 → 不寫 marker（下次重試）、不炸
pwb.setup({ options = {} })
pwb.run()
assert(pwb.state().files[pwb.marker] == nil, "W4: 選項缺失仍寫了 marker（翻轉被永久跳過）")

-- W5. modOptions nil（無 PZAPI）→ 不寫 marker、不炸
pwb.setup({ noModOptions = true })
pwb.run()
assert(pwb.state().files[pwb.marker] == nil, "W5: 無 PZAPI 仍寫了 marker")

-- W6. marker 寫入失敗（getFileWriter 回 nil）→ 讀回驗證擋下：不翻值、不 save、
-- log 一筆 skip；下次重試。fail closed 的核心案例：翻值在先會在 marker 永遠
-- 寫不進去時每次啟動重翻、覆蓋玩家的刻意關閉（codex review 反例）
local w6 = mkTick(false)
pwb.setup({ options = { PoiWholeBuilding = w6 }, failWrite = true })
pwb.run()
assert(w6.value == false, "W6: marker 未落地仍翻了值（重複干預風險）")
assert(pwb.state().saveCalls == 0, "W6: marker 未落地不應 save")
assert(pwb.state().files[pwb.marker] == nil, "W6: failWrite 下不應有 marker")
assert(#pwb.state().logs == 1, "W6: 應 log 一筆 skip 訊息")

--------------------------------------------------------------------------------
-- 圖片化開關 apply 決策矩陣（computeApplyPlan，主檔）：世界地圖/小地圖分側動作
--------------------------------------------------------------------------------
local mainPath = arg[3]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"
local planBody = assert(readSource(mainPath):match(
    "%-%- test:apply%-plan:start\n(.-)\n%-%- test:apply%-plan:end"),
    "找不到 apply-plan 測試區段")
local planChunk, planErr = compile(planBody .. "\nreturn computeApplyPlan")
assert(planChunk, planErr)
local plan = planChunk()

local PLAN_BASE = { imagery = true, packLayers = true, sizeIndex = 2, customSize = "" }
local function planCur(over)
    local c = {}
    for k, v in pairs(PLAN_BASE) do c[k] = v end
    for k, v in pairs(over or {}) do c[k] = v end
    return c
end
local function planSnap(over)
    local s = { worldImagery = true, hasMiniMap = true,
        imagery = true, packLayers = true, sizeIndex = 2, customSize = "" }
    for k, v in pairs(over or {}) do s[k] = v end
    return s
end

-- P1. 關閉圖片化（雙側都有）→ 世界地圖卸載＋小地圖重建、非 live
local p = plan(planSnap(), planCur({ imagery = false }))
assert(p.reapplyWorldMap and p.recreate and not p.live and not p.clearCustomSize, "P1: 雙側切換動作不齊")

-- P2. 無小地圖（沙盒 AllowMiniMap 關）仍要能切世界地圖
p = plan(planSnap({ hasMiniMap = false }), planCur({ imagery = false }))
assert(p.reapplyWorldMap and not p.recreate and not p.live, "P2: 無小地圖時世界地圖切換失效")

-- P3. 世界地圖從未掛載（worldImagery=nil）→ 不動世界地圖、小地圖照常。
-- nil 無法經 override 表傳遞（nil 鍵不存在、蓋不掉基底值）——手組快照
p = plan({ hasMiniMap = true, imagery = true, packLayers = true, sizeIndex = 2, customSize = "" },
    planCur({ imagery = false }))
assert(not p.reapplyWorldMap and p.recreate, "P3: 未掛載仍動世界地圖")

-- P4. imagery＋尺寸同改：不可漏清自訂尺寸（舊 elseif 鏈的漏洞）
p = plan(planSnap({ customSize = "300x240" }),
    planCur({ imagery = false, sizeIndex = 3, customSize = "300x240" }))
assert(p.reapplyWorldMap and p.clearCustomSize and p.recreate, "P4: 同改漏清自訂尺寸")

-- P5. 只改尺寸（自訂為空）→ 重建、不清
p = plan(planSnap(), planCur({ sizeIndex = 3 }))
assert(p.recreate and not p.clearCustomSize and not p.reapplyWorldMap, "P5")

-- P6. 只改自訂尺寸欄（含手動清空還原）→ 重建
p = plan(planSnap(), planCur({ customSize = "300x240" }))
assert(p.recreate and not p.clearCustomSize, "P6")

-- P7. 只改地圖包開關 → 重建、不動世界地圖 imagery
p = plan(planSnap(), planCur({ packLayers = false }))
assert(p.recreate and not p.reapplyWorldMap, "P7")

-- P8. 全無變動 → 只走 live（純開關即時路徑）
p = plan(planSnap(), planCur())
assert(p.live and not p.recreate and not p.reapplyWorldMap and not p.clearCustomSize, "P8")

-- P9. 重新開啟圖片化 → 雙側恢復
p = plan(planSnap({ worldImagery = false, imagery = false }), planCur())
assert(p.reapplyWorldMap and p.recreate, "P9")

print("[OK] scripts/test_key_migration.lua 全部通過（快捷鍵遷移 A-G、拖曳 H-K、選項遷移 M1-M5、強制圖片化 V1-V5、整棟預設翻轉 W1-W6、apply 決策 P1-P9）")
