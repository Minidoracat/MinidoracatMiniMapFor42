-- 一次性快捷鍵遷移（HOME→/）＋浮動圖標拖曳門檻回歸測試。
-- 仿 test_zone_render.lua 的 stub 風格：抽主檔標記區段→補最小 stub→組裝可離線跑。
-- 用法：lua scripts/test_key_migration.lua
local sourcePath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"

local file = assert(io.open(sourcePath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()

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
local dragBody = assert(source:match(
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

print("[OK] scripts/test_key_migration.lua 全部通過（快捷鍵遷移 A-G、拖曳 H-K、選項遷移 M1-M5）")
