-- 小地圖位置記憶（_Resize.lua test:layout-memory 區段）離線回歸：自建小地圖登記版面、拖曳放開就寫檔、
-- 下次登記讀回（收合 y 換算）、舊檔相容、重建帶過位置並改登記、沒登記或沒拖不寫。
-- 假 ISLayoutManager 照原版 ISLayoutManager.lua 的流程寫（RegisterWindow:6-13、DefaultRestoreWindow:15-51、
-- DefaultSaveWindow:53-60、TryRestore:77-97、ReadIni:125-167、WriteIni:169-186、OnPostSave:191-230），
-- layout.ini 換成字串，值照原版經字串存讀；小地圖版面存讀照 ISMiniMap.lua:660-670。
local sourcePath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Resize.lua"

local function readAll(path)
    local fh = assert(io.open(path, "rb"), "開不了 " .. path)
    local text = fh:read("*a"):gsub("\r\n", "\n")
    fh:close()
    return text
end
local body = assert(readAll(sourcePath):match(
    "\n%-%- test:layout%-memory:start\n(.-)\n%-%- test:layout%-memory:end"),
    "找不到 test:layout-memory 區段")
local compile = loadstring or load

local failures = 0
local function check(value, label)
    if not value then failures = failures + 1; print("FAIL " .. label) end
end

--------------------------------------------------------------------------------
-- 假原版
--------------------------------------------------------------------------------
local SCREEN_W, SCREEN_H, TH = 1920, 1080, 18
local DEFAULT_X, DEFAULT_Y = 1700, 700 -- 新小地圖的右下預設位置（收合時）
local file, writes = nil, 0 -- layout.ini 內容（nil＝沒有檔）、寫檔次數

ISLayoutManager = { windows = {} }
function ISLayoutManager.RegisterWindow(name, funcs, target)
    ISLayoutManager.windows[name] = { funcs = funcs, target = target }
    ISLayoutManager.TryRestore(name)
end
function ISLayoutManager.DefaultRestoreWindow(window, layout)
    local x, y = tonumber(layout.x), tonumber(layout.y)
    if x and y then window:setX(x); window:setY(y) end
    if layout.visible == "true" then
        window:addToUIManager()
        window:setVisible(true)
    elseif layout.visible == "false" then
        window:setVisible(false)
    end
end
function ISLayoutManager.DefaultSaveWindow(window, layout)
    layout.x, layout.y = window:getX(), window:getY()
    layout.width, layout.height = window:getWidth(), window:getHeight()
    layout.visible = tostring(window:getIsVisible())
end
function ISLayoutManager.TryRestore(name)
    if ISLayoutManager.layouts == nil then ISLayoutManager.ReadIni() end
    for _, res in pairs(ISLayoutManager.layouts) do
        if res.width == SCREEN_W and res.height == SCREEN_H then
            for _, layout in pairs(res.windows) do
                if layout.name == name then
                    local w = ISLayoutManager.windows[name]
                    return w.funcs.RestoreLayout(w.target, name, layout)
                end
            end
        end
    end
end
function ISLayoutManager.ReadIni()
    ISLayoutManager.layouts = {}
    local res
    for line in (file or ""):gmatch("[^\r\n]+") do
        local w, h = line:match("^%[(%d+)x(%d+)%]$")
        if w then
            res = { width = tonumber(w), height = tonumber(h), windows = {} }
            table.insert(ISLayoutManager.layouts, res)
        else
            local layout = {}
            for word in line:gmatch("%S+") do
                local k, v = word:match("^([^=]+)=(.*)$")
                if k then layout[k] = v else layout.name = word end
            end
            table.insert(res.windows, layout)
        end
    end
end
function ISLayoutManager.WriteIni()
    local out = {}
    for _, res in pairs(ISLayoutManager.layouts) do
        out[#out + 1] = "[" .. res.width .. "x" .. res.height .. "]\r\n"
        for _, layout in pairs(res.windows) do
            local s = layout.name
            for k, v in pairs(layout) do
                if k ~= "name" then s = s .. " " .. k .. "=" .. tostring(v) end
            end
            out[#out + 1] = s .. "\r\n"
        end
    end
    file, writes = table.concat(out), writes + 1
end
function ISLayoutManager.OnPostSave()
    local cur
    for _, res in pairs(ISLayoutManager.layouts) do
        if res.width == SCREEN_W and res.height == SCREEN_H then cur = res; break end
    end
    if not cur then
        cur = { width = SCREEN_W, height = SCREEN_H, windows = {} }
        table.insert(ISLayoutManager.layouts, cur)
    end
    for name, w in pairs(ISLayoutManager.windows) do
        local wl
        for _, layout in pairs(cur.windows) do
            if layout.name == name then wl = layout; break end
        end
        if not wl then wl = { name = name }; table.insert(cur.windows, wl) end
        w.funcs.SaveLayout(w.target, name, wl)
    end
    ISLayoutManager.WriteIni()
end

ISMiniMapOuter = {}
function ISMiniMapOuter:RestoreLayout(name, layout)
    ISLayoutManager.DefaultRestoreWindow(self, layout)
    self.userPosition = layout.userPosition == "true"
end
function ISMiniMapOuter:SaveLayout(name, layout)
    ISLayoutManager.DefaultSaveWindow(self, layout)
    layout.width, layout.height = nil, nil
    layout.userPosition = self.userPosition and "true" or "false"
end

ISMiniMapTitleBar = {}
function ISMiniMapTitleBar:onMouseUp() self.dragging = false; return true end
function ISMiniMapTitleBar:onMouseUpOutside() self.dragging = false; return true end

-- adorned＝標題列展開（「永遠顯示」模式建好就展開，外框上移標題列高，ISMiniMap.lua:479-497）
local function newMiniMap(pn, adorned)
    local mm = setmetatable({ playerNum = pn, x = DEFAULT_X, y = DEFAULT_Y - (adorned and TH or 0),
        width = 200, height = 200, visible = true }, { __index = ISMiniMapOuter })
    function mm:getX() return self.x end
    function mm:getY() return self.y end
    function mm:setX(v) self.x = v end
    function mm:setY(v) self.y = v end
    function mm:getWidth() return self.width end
    function mm:getHeight() return self.height end
    function mm:setVisible(v) self.visible = v end
    function mm:getIsVisible() return self.visible end
    function mm:addToUIManager() self.inUI = true end
    function mm:removeFromUIManager() self.inUI = false end
    mm.titleBar = setmetatable({ height = TH, shown = adorned, miniMap = mm, dragging = false },
        { __index = ISMiniMapTitleBar })
    function mm.titleBar:isVisible() return self.shown end
    return mm
end

local players, nextAdorned = {}, true
ISMiniMap = {}
function ISMiniMap.Recreate(pn) -- 原版 ISMiniMap.lua:778-781
    players[pn]:removeFromUIManager()
    players[pn] = newMiniMap(pn, nextAdorned)
end
function getPlayerMiniMap(pn) return players[pn] end

Core = {}
compile(body, "=layout-memory")()

-- 檔案裡目前解析度那一段的某個視窗（照 ReadIni 解析，值是字串）
local function saved(name)
    local res
    for line in (file or ""):gmatch("[^\r\n]+") do
        local w, h = line:match("^%[(%d+)x(%d+)%]$")
        if w then
            res = tonumber(w) == SCREEN_W and tonumber(h) == SCREEN_H
        elseif res and line:match("^(%S+)") == name then
            local t = {}
            for k, v in line:gmatch("(%S+)=(%S+)") do t[k] = v end
            return t
        end
    end
end
-- 模擬下一次進遊戲：登記清空、版面從檔案重讀（原版第一次登記時 ReadIni）
local function newSession()
    ISLayoutManager.windows = {}
    ISLayoutManager.layouts = nil
end
local function drag(mm, x, y, outside)
    mm.userPosition = true -- 原版拖曳中設的（ISMiniMap.lua:387-389）
    mm:setX(x)
    mm:setY(y)
    mm.titleBar.dragging = true
    if outside then ISMiniMapTitleBar.onMouseUpOutside(mm.titleBar, 0, 0)
    else ISMiniMapTitleBar.onMouseUp(mm.titleBar, 0, 0) end
end

--------------------------------------------------------------------------------
-- L1 自建小地圖：登記後拖曳放開就寫檔；下次進遊戲讀回，收合／展開各自換算 y
--------------------------------------------------------------------------------
newSession()
file = nil
local mm = newMiniMap(0, true)
players[0] = mm
Core.registerMiniMapLayout(mm)
check(ISLayoutManager.windows.miniMap0 and ISLayoutManager.windows.miniMap0.target == mm,
    "L1 自建小地圖登記到 miniMap0")
check(mm.x == DEFAULT_X and mm.userPosition == nil, "L1 沒有舊版面時照原版右下預設")
local before = writes
drag(mm, 300, 200)
local line = saved("miniMap0")
check(writes == before + 1, "L1 標題列拖曳放開就寫檔（不等離開遊戲）")
check(line and line.x == "300" and line.userPosition == "true", "L1 存了拖到的 x 與 userPosition")
check(line and tonumber(line.baseY) == 200 + TH, "L1 baseY 是收合時的 y（展開時 y＋標題列高）")

newSession()
local hover = newMiniMap(0, false) -- 「滑鼠懸停時」或穿透：建好是收合的
players[0] = hover
Core.registerMiniMapLayout(hover)
check(hover.x == 300 and hover.y == 200 + TH and hover.userPosition == true,
    "L1 下次進遊戲讀回：收合的新視窗 y＝baseY")

newSession()
local always = newMiniMap(0, true)
players[0] = always
Core.registerMiniMapLayout(always)
check(always.x == 300 and always.y == 200, "L1 下次進遊戲讀回：展開的新視窗 y＝baseY－標題列高")

--------------------------------------------------------------------------------
-- L2 舊檔（原版寫的，沒有 baseY）照原版只用 y；L3 舊版面 visible=false 不把要開的小地圖藏起來
--------------------------------------------------------------------------------
newSession()
file = "[1920x1080]\r\nminiMap0 x=100 y=50 visible=false userPosition=true\r\n"
local legacy = newMiniMap(0, true)
players[0] = legacy
Core.registerMiniMapLayout(legacy)
check(legacy.x == 100 and legacy.y == 50 and legacy.userPosition == true, "L2 舊檔沒有 baseY：x、y 照原版")
check(legacy.visible == true, "L3 舊版面 visible=false：自己開的小地圖仍可見")

newSession()
file = "[1280x720]\r\nminiMap0 x=10 y=10 visible=true userPosition=true baseY=28\r\n"
local otherRes = newMiniMap(0, true)
players[0] = otherRes
Core.registerMiniMapLayout(otherRes)
check(otherRes.x == DEFAULT_X and not otherRes.userPosition, "L2 別的解析度那一段不套用（原版行為）")

--------------------------------------------------------------------------------
-- L4 重建：帶過位置（含收合／展開換算）、登記改指新視窗、之後存的是新視窗
--------------------------------------------------------------------------------
newSession()
file = nil
local old = newMiniMap(0, true)
players[0] = old
Core.registerMiniMapLayout(old)
drag(old, 400, 300)
nextAdorned = false -- 重建時剛好是收合的（穿透模式）
ISMiniMap.Recreate(0)
local new = getPlayerMiniMap(0)
check(new ~= old, "L4 重建換了新視窗")
check(new.userPosition == true and new.x == 400 and new.y == 300 + TH, "L4 重建帶過位置：收合的新視窗 y＝舊的收合 y")
check(ISLayoutManager.windows.miniMap0.target == new, "L4 版面登記改指新視窗")
new:setX(500)
ISLayoutManager.OnPostSave() -- 離開遊戲
line = saved("miniMap0")
check(line and line.x == "500" and tonumber(line.baseY) == 300 + TH, "L4 之後存的是新視窗的位置")
nextAdorned = true
ISMiniMap.Recreate(0)
check(getPlayerMiniMap(0).x == 500 and getPlayerMiniMap(0).y == 300, "L4 再重建成展開的：y＝收合 y－標題列高")

--------------------------------------------------------------------------------
-- L5 沒拖過：重建照原版右下，不寫 userPosition
--------------------------------------------------------------------------------
newSession()
file = nil
local fresh = newMiniMap(0, true)
players[0] = fresh
Core.registerMiniMapLayout(fresh)
ISMiniMap.Recreate(0)
check(getPlayerMiniMap(0).x == DEFAULT_X and getPlayerMiniMap(0).userPosition == nil, "L5 沒拖過的重建照原版右下")

--------------------------------------------------------------------------------
-- L6 不該寫檔：沒登記的小地圖（分割畫面 1 號玩家，原版不登記）、沒按下標題列（dragging 是 false）卻收到放開；
-- 原版 onMouseDown 一按就設 dragging（ISMiniMap.lua:363-369），所以點一下沒移動也會存一次，無害。L7 拖出視窗外放開也存
--------------------------------------------------------------------------------
local p1 = newMiniMap(1, true)
players[1] = p1
before = writes
drag(p1, 50, 60)
check(writes == before, "L6 沒登記的小地圖放開不寫檔")
p1.userPosition = nil
ISMiniMap.Recreate(1)
check(getPlayerMiniMap(1).x == DEFAULT_X, "L6 沒登記、沒拖過的重建不動")
before = writes
ISMiniMapTitleBar.onMouseUp(getPlayerMiniMap(0).titleBar, 0, 0) -- dragging 是 false
check(writes == before, "L6 沒按下標題列（dragging=false）收到放開不寫檔")
drag(getPlayerMiniMap(0), 640, 480, true)
check(writes == before + 1 and saved("miniMap0").x == "640", "L7 拖出視窗外放開（onMouseUpOutside）也存")

--------------------------------------------------------------------------------
-- L8 手把玩家開著背包：原版把 Java x 移到螢幕外、真正的 x 記在 hideInventoryX（ISMiniMap.lua:499-515）；
-- 假視窗的 getX 回 self.x，所以把 x 設成螢幕外來模擬。這個欄位只在手把分支裡清，手把斷線改鍵鼠
-- （JoyPadSetup.lua useKeyboardMouse 把 JoypadState.players[n] 設 nil）後留著舊值，之後拖的位置才是對的
--------------------------------------------------------------------------------
JoypadState = { players = { {} } }
local pad = getPlayerMiniMap(0)
pad.hideInventoryX, pad.x = 700, SCREEN_W + 100
ISLayoutManager.OnPostSave()
check(saved("miniMap0").x == "700", "L8 背包開著時離開遊戲：存的是藏起來前的 x")
ISMiniMap.Recreate(0)
check(getPlayerMiniMap(0).x == 700, "L8 背包開著時重建：帶過藏起來前的 x")
JoypadState.players[1] = nil
local stale = getPlayerMiniMap(0)
stale.hideInventoryX = 700
drag(stale, 900, 400)
check(saved("miniMap0").x == "900", "L8 手把斷線改鍵鼠後留著舊 hideInventoryX：拖曳放開存的是新位置")
ISMiniMap.Recreate(0)
check(getPlayerMiniMap(0).x == 900, "L8 手把斷線改鍵鼠後重建：帶的是現在的 x")
JoypadState = nil

if failures > 0 then
    print(("minimap layout memory: %d check(s) failed"):format(failures))
    os.exit(1)
end
print("minimap layout memory: register/restore, base y, legacy file, recreate carry, save-on-release, joypad hidden x cases passed")
