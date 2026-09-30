-- 小地圖重建（ISMiniMap.Recreate 包裝）後的 UI 疊放順序離線回歸。
-- 抽主檔 test:recreate-zorder 區段，配照 UIManager.java 佇列語意寫的假 UIManager：
--   AddUI／RemoveElement 只進 toAdd／toRemove（:112-123）；update 先 removeAll／addAll（:497-506），
--   再把 alwaysOnTop 與 toTop 依清單順序搬到尾端（:546-560）；bringToTop＝pushToTop（UIElement.java:958-962）。
-- 原版 Recreate 照 ISMiniMap.lua:778-781：舊 outer removeFromUIManager、InitPlayer 建新 outer，
-- StartVisible 時 addToUIManager（:741-743）。每案只跑一次 update 就驗：重排必須和新 outer
-- 附加發生在同一次 update，否則會有一幀小地圖蓋住世界地圖。
local sourcePath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"

local function readAll(path)
    local fh = assert(io.open(path, "rb"), "開不了 " .. path)
    local text = fh:read("*a"):gsub("\r\n", "\n")
    fh:close()
    return text
end

local body = assert(readAll(sourcePath):match(
    "\n%-%- test:recreate%-zorder:start\n(.-)\n%-%- test:recreate%-zorder:end"),
    "找不到 test:recreate-zorder 區段")
local compile = loadstring or load

local failures = 0
local function check(value, label)
    if not value then failures = failures + 1; print("FAIL " .. label) end
end

--------------------------------------------------------------------------------
-- 假 UIManager（Java 端）
--------------------------------------------------------------------------------
local UI, toAdd, toRemove, toTop = {}, {}, {}, {}

local function removeAll(list, el)
    for i = #list, 1, -1 do
        if list[i] == el then table.remove(list, i) end
    end
end
local function contains(list, el)
    for i = 1, #list do
        if list[i] == el then return true end
    end
    return false
end

UIManager = {
    getUI = function()
        return { size = function() return #UI end, get = function(_, i) return UI[i + 1] end }
    end,
}

local function update()
    for i = 1, #toRemove do removeAll(UI, toRemove[i]) end
    toRemove = {}
    for i = 1, #toAdd do UI[#UI + 1] = toAdd[i] end
    toAdd = {}
    local i = 1
    while i <= #UI do
        local el = UI[i]
        if el.alwaysOnTop or contains(toTop, el) then
            table.remove(UI, i)
            toAdd[#toAdd + 1] = el
        else
            i = i + 1
        end
    end
    for k = 1, #toAdd do UI[#UI + 1] = toAdd[k] end
    toAdd, toTop = {}, {}
end

local function newPanel(name, alwaysOnTop)
    local java = { name = name, alwaysOnTop = alwaysOnTop or false }
    function java:bringToTop() toTop[#toTop + 1] = self end
    local p = { name = name, javaObject = java }
    function p:addToUIManager()
        removeAll(toRemove, self.javaObject); toRemove[#toRemove + 1] = self.javaObject
        removeAll(toAdd, self.javaObject); toAdd[#toAdd + 1] = self.javaObject
    end
    function p:removeFromUIManager()
        removeAll(toAdd, self.javaObject); removeAll(toRemove, self.javaObject)
        toRemove[#toRemove + 1] = self.javaObject
    end
    function p:setVisible(v) self.visible = v end
    return p
end

--------------------------------------------------------------------------------
-- 假原版 Recreate／小地圖
--------------------------------------------------------------------------------
local players, startVisible, serial = {}, true, 0

local function newMiniMap()
    serial = serial + 1
    local mm = newPanel("mini" .. serial)
    local flags = {}
    mm.inner = { mapAPI = {
        getBoolean = function(_, k) return flags[k] == true end,
        setBoolean = function(_, k, v) flags[k] = v end,
    } }
    return mm
end

ISMiniMap = {
    Recreate = function(pn)
        players[pn]:removeFromUIManager()
        local mm = newMiniMap()
        if startVisible then mm:addToUIManager() end
        players[pn] = mm
    end,
}
function getPlayerMiniMap(pn) return players[pn] end
function setJoypadFocus() end

compile(body, "=recreate-zorder")()

-- names：UIManager 由下而上的順序，"mini" 是玩家 0 的小地圖；回傳 name→panel
local function scene(names, opts)
    opts = opts or {}
    UI, toAdd, toRemove, toTop = {}, {}, {}, {}
    startVisible = opts.startVisible ~= false
    local panels = {}
    players[0] = newMiniMap()
    for _, name in ipairs(names) do
        local p = name == "mini" and players[0] or newPanel(name, name == "floaticon")
        panels[name] = p
        UI[#UI + 1] = p.javaObject
    end
    -- 遊戲裡的世界地圖單例（ISWorldMap.lua:1500 ShowWorldMap 建立）；只拉它的寫法會在 B 案露餡
    ISWorldMap_instance = panels.worldmap
    if ISWorldMap_instance then
        function ISWorldMap_instance:isVisible() return true end
        function ISWorldMap_instance:bringToTop() self.javaObject:bringToTop() end
    end
    if not panels.mini then panels.mini = players[0] end
    return panels
end

local function order()
    local out = {}
    for i = 1, #UI do
        out[i] = UI[i] == players[0].javaObject and "mini" or UI[i].name
    end
    return table.concat(out, ",", 1, #out)
end

local function recreate(label, names, expected, opts)
    local panels = scene(names, opts)
    local old = players[0]
    if opts and opts.topLevelPanel then
        old.optionsUI = panels[opts.topLevelPanel]
        old.optionsUI._minidoracatTopLevel = true
    end
    ISMiniMap.Recreate(0)
    update()
    check(players[0] ~= old, label .. "：應換成新 outer")
    check(not contains(UI, old.javaObject), label .. "：舊 outer 應離開 UIManager")
    local actual = order()
    check(actual == expected, label .. "：順序 expected=" .. expected .. " actual=" .. actual)
end

-- A. 世界地圖選項面板切「圖片化地圖」：世界地圖留在新小地圖之上
recreate("A 世界地圖開著", { "hud", "mini", "worldmap" }, "hud,mini,worldmap")
-- B. 世界地圖爪印鈕開的設定視窗疊在世界地圖上：三者相對順序不變（只拉世界地圖會把設定視窗壓到下面）
recreate("B 設定視窗在世界地圖上", { "mini", "worldmap", "studio" }, "mini,worldmap,studio")
-- C. 原本在小地圖下方的視窗不被抬上來，上方的維持原順序
recreate("C 上下都有視窗", { "inventory", "mini", "chat", "worldmap" }, "inventory,mini,chat,worldmap")
-- D. 小地圖原本就在最上層：重建後仍在最上層
recreate("D 小地圖最上層", { "inventory", "mini" }, "inventory,mini")
-- E. 小地圖隱藏（不在 UIManager、StartVisible 關）：其他視窗順序不動，新小地圖也不出現
recreate("E 小地圖隱藏", { "inventory", "worldmap" }, "inventory,worldmap", { startVisible = false })
-- F. 搬到頂層的齒輪面板在小地圖上方：面板照舊移除，不因推頂而復活
recreate("F 頂層齒輪面板", { "mini", "gearpanel", "worldmap" }, "mini,worldmap", { topLevelPanel = "gearpanel" })
-- G. 原生置頂元件（浮動圖標）仍在最上層
recreate("G 置頂元件", { "mini", "worldmap", "floaticon" }, "mini,worldmap,floaticon")

if failures > 0 then
    print(("recreate z-order: %d check(s) failed"):format(failures))
    os.exit(1)
end
print("recreate z-order: world map/settings stay above, below stays below, hidden/top-level/always-on-top cases passed")
