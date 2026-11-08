-- 手繪工具（client/MinidoracatMiniMap_SketchTool.lua）離線回歸：原版工具基底照 ISWorldMapSymbols.lua:11-88 的
-- 語意換成假件，地圖投影用固定比例。守的是玩家碰得到的行為：按下回 true（地圖不平移）、拖曳每 2 px 取一點、
-- Shift 與直線模式只存 2 點、右鍵拖曳平移、右鍵點一下＝復原、Backspace／Shift+Backspace、沒有筆拒畫、
-- 各色是否可選和原版寫法一致、沒有橡皮擦不能擦、拖曳擦除合成一步、手把 A 下筆／停筆、X 只在本工具作用中才攔、
-- deactivate 把畫到一半的那筆存起來並寫檔、復原最多 50 步、清除全部可復原、500 點自動接成下一筆。
-- 用法：lua scripts/test_sketch_tool.lua
local H = dofile("scripts/sketch_harness.lua")
local Core = H.boot({ tool = true })
local SK, ST, check = H.SK, Core.SketchTool, H.check
local C = MinidoracatMiniMapSketchCodec
local player = H.player("alice", 0)
H.players[0] = player
H.fire("OnCreatePlayer", 0)
local slot = H.loadSlot(0)
local map = H.worldMap({ S = 4, cx = 1000, cy = 1000, zoom = 16.6 })
local sym = map.symbolsUI
local P0 = "MinidoracatMiniMap/sketch/Sandbox/w1_p0.txt"

local function at(wx, wy) return (wx - map.mapAPI.cx) * 4 + 400, (wy - map.mapAPI.cy) * 4 + 300 end
local function down(t, wx, wy)
    map.mouse.x, map.mouse.y = at(wx, wy)
    return t:onMouseDown(map.mouse.x, map.mouse.y)
end
local function move(t, wx, wy)
    map.mouse.x, map.mouse.y = at(wx, wy)
    return t:onMouseMove(0, 0)
end
local function up(t) return t:onMouseUp(map.mouse.x, map.mouse.y) end
local function last() return slot.store.strokes[slot.store.count] end

check(Core.sketchToolStart(0) == true, "T0 筆鈕開工具")
local tool = Core.sketchToolOf(map)
check(tool ~= nil and tool.bar ~= nil and tool.bar.parent == map, "T1 工具開著、工具列掛在地圖上")

-- 沒有筆：按下回 true（地圖不平移）但不畫，提示要筆
H.messages = {}
check(down(tool, 1000, 1000) == true, "N1 按下回 true，地圖不平移")
move(tool, 1010, 1000)
up(tool)
check(slot.store.count == 0 and H.messages[1] == "UI_MinidoracatMiniMap_SketchNeedPen", "N2 沒有筆或鉛筆拒畫並提示")

-- 有黑筆與紅筆：各色是否可選與原版一致；選了沒有的色不換
player.items = { Pen = true, RedPen = true }
local inv = tool:refreshInv()
check(inv.canWrite and inv.have[1] and not inv.have[2] and inv.have[3] and not inv.have[4] and not inv.have[5],
    "I1 身上有的筆才可選（黑、紅）")
tool:setColor(4)
check(tool.prefs.c == 1, "I2 沒有藍筆選不了")
tool:setColor(3)
check(tool.prefs.c == 3, "I3 紅筆可選")
player.items = { Pen = true }
tool:refreshInv()
check(tool.prefs.c == 1, "I4 紅筆不見了：自動換回第一個有的色（同原版 checkInventory）")
player.items = { Pen = true, RedPen = true }
tool:refreshInv()

-- 自由畫：每 2 px 取一點；停筆存一筆、縮放四捨五入
down(tool, 1000, 1000)
move(tool, 1000.2, 1000) -- 0.8 px：不取
check(tool.cur.np == 1, "D1 不到 2 px 不取點")
move(tool, 1001, 1000.5)
move(tool, 1002, 1002)
move(tool, 1004, 1001)
up(tool)
local s = last()
check(slot.store.count == 1 and s.np == 4 and s.z == 17 and s.c == 1 and s.w == 2, "D2 停筆存一筆（4 點、縮放 17）")
check(#tool.undoStack == 1, "D3 記一步")

-- Shift 只存起點與終點；直線模式同
H.shift = true
down(tool, 1000, 1010)
move(tool, 1003, 1012)
move(tool, 1006, 1010)
up(tool)
H.shift = false
check(last().np == 2 and last().pts[3] == 1006, "S1 按住 Shift 只存 2 點")
tool:setMode("line")
down(tool, 1000, 1020)
move(tool, 1005, 1025)
move(tool, 1010, 1020)
up(tool)
check(last().np == 2 and last().pts[3] == 1010 and last().pts[4] == 1020, "S2 直線模式只存 2 點")
tool:setMode("pen")

-- 右鍵拖曳＝平移（照原版公式 centerOn），不復原；右鍵點一下＝復原
local n0 = slot.store.count
H.rightDown = true
map.mouse.x, map.mouse.y = 400, 300
check(tool:onRightMouseDown(400, 300) == true, "R1 右鍵按下回 true")
map.mouse.x = 440
tool:onMouseMove(40, 0)
check(math.abs(map.mapAPI.cx - 990) < 1e-6, "R2 右鍵拖曳把地圖往左移 10 格")
H.rightDown = false
tool:onRightMouseUp(440, 300)
check(slot.store.count == n0, "R3 拖曳後放開不復原")
map.mapAPI.cx = 1000
tool:onRightMouseDown(400, 300)
tool:onRightMouseUp(400, 300)
check(slot.store.count == n0 - 1 and #tool.redoStack == 1, "R4 右鍵點一下＝復原")

-- Backspace 復原、Shift+Backspace 重做；isKeyConsumed 吃 Backspace
check(tool:isKeyConsumed(Keyboard.KEY_BACK) == true and tool:isKeyConsumed(Keyboard.KEY_RETURN) == false, "K1 只吃 Backspace")
H.shift = true
tool:onKeyRelease(Keyboard.KEY_BACK)
H.shift = false
check(slot.store.count == n0, "K2 Shift+Backspace 重做")
tool:onKeyRelease(Keyboard.KEY_BACK)
check(slot.store.count == n0 - 1, "K3 Backspace 復原")
tool:onKeyRelease(Keyboard.KEY_BACK)
tool:onKeyRelease(Keyboard.KEY_BACK)
check(slot.store.count == 0 and #tool.undoStack == 0, "K4 一路復原到空")
tool:onKeyRelease(Keyboard.KEY_BACK)
check(slot.store.count == 0, "K5 沒有可復原的不出錯")
H.shift = true
for _ = 1, 3 do tool:onKeyRelease(Keyboard.KEY_BACK) end
H.shift = false
check(slot.store.count == 3, "K6 一路重做回來")

-- 橡皮擦：沒有就不能擦；拖曳擦除合成一步、復原一次全部回來
tool:setMode("erase")
H.messages = {}
down(tool, 1002, 1002)
up(tool)
check(slot.store.count == 3 and H.messages[1] == "Tooltip_Map_CantErase", "E1 沒有橡皮擦不能擦")
player.items["Base.Eraser"] = true
local before = slot.store.count
down(tool, 1005, 1020) -- 直線（1000..1010, 1020）的中間
move(tool, 1003, 1010)
move(tool, 1001, 1001)
up(tool)
check(slot.store.count ~= before and #tool.undoStack == 4, "E2 拖曳擦除合成一步")
tool:undo()
check(slot.store.count == before and last().np == 2, "E3 復原一次全部回來")
tool:setMode("pen")

-- 手把：A 下筆，準星跟著地圖移動取點；再按 A 停筆
local n1 = slot.store.count
map.mapAPI.cx, map.mapAPI.cy = 1100, 1100
tool:onJoypadDownInMap(Joypad.AButton)
check(tool.padDown == true and tool:getJoypadAButtonText() == "UI_MinidoracatMiniMap_SketchPadUp", "J1 A 下筆")
for k = 1, 5 do
    map.mapAPI.cx = 1100 + k
    tool:render()
end
check(tool:onMouseUp(0, 0) == false and tool.cur.np == 6, "J2 搖桿捲動時在準星取點（滑鼠放開不停筆）")
tool:onJoypadDownInMap(Joypad.AButton)
check(not tool.padDown and slot.store.count == n1 + 1 and last().pts[1] == 1100, "J3 再按 A 停筆存一筆")

-- 手把 X：只在手繪工具作用中攔，其他情況照原版
do
    local src = H.read(H.LUA .. "client/MinidoracatMiniMap_WorldMapNav.lua")
    local snippet = assert(src:match("(if ISWorldMap and ISWorldMap.onJoypadDown then.-\nend)\n%-%- test:wm%-prerender:end"))
    local vanilla = {}
    ISWorldMap = { onJoypadDown = function(self, b) vanilla[#vanilla + 1] = b end }
    assert(load(snippet, "=joypad-x", "t", setmetatable({ Core = Core }, { __index = _G })))()
    H.menus = {}
    ISWorldMap.onJoypadDown(map, Joypad.XButton, { player = 0 })
    check(#vanilla == 0 and #H.menus == 1, "X1 手繪中 X 開手繪選單、不走原版")
    ISWorldMap.onJoypadDown(map, Joypad.AButton, { player = 0 })
    check(#vanilla == 1, "X2 其他鍵照原版")
    local items = H.menus[1].options
    local hasBlue
    for _, o in ipairs(items) do
        if o.a == "color" and o.b == 4 then hasBlue = o.notAvailable end
    end
    check(#items == 3 + 5 + 3 + 4 and hasBlue == true, "X3 選單：模式、五色（藍灰）、粗細、復原重做清除離開")
    sym:setCurrentTool(nil)
    ISWorldMap.onJoypadDown(map, Joypad.XButton, { player = 0 })
    check(#vanilla == 2, "X4 工具沒開時 X 照原版")
    Core.sketchToolStart(0)
    tool = Core.sketchToolOf(map)
end

-- deactivate：畫到一半的那筆存起來，並立刻寫檔
H.writes = {}
local n2 = slot.store.count
down(tool, 1000, 1030)
move(tool, 1005, 1030)
sym:setCurrentTool(nil)
check(slot.store.count == n2 + 1 and #H.writes == 2 and H.writes[2] == P0, "Q1 關工具存下畫到一半的那筆並寫檔")
check(tool.bar == nil, "Q2 工具列拿掉")

-- 再開一次：復原堆疊是新的；最多 50 步；清除全部可復原
Core.sketchToolStart(0)
tool = Core.sketchToolOf(map)
check(#tool.undoStack == 0, "U1 每次開工具一份復原堆疊")
for k = 1, 55 do
    down(tool, 1200 + k, 1200)
    up(tool)
end
check(#tool.undoStack == ST.UNDO_MAX, "U2 復原最多 50 步")
local total = slot.store.count
-- 清除全部也是擦：沒有橡皮擦就拒（工具列與手把選單同一個判定；復原、重做不用物品）
player.items["Base.Eraser"] = nil
H.messages = {}
check(tool:clearAll() == false and slot.store.count == total and H.messages[1] == "Tooltip_Map_CantErase",
    "U3a 沒有橡皮擦不能清除全部")
local clearItem
for _, it in ipairs(ST.menuItems(tool)) do if it.op == "clear" then clearItem = it end end
tool.bar:prerender()
check(clearItem and clearItem.off ~= nil and tool.bar.btns.clear.enable == false, "U3b 手把選單與工具列的清除全部都灰掉")
player.items["Base.Eraser"] = true
tool:clearAll()
check(slot.store.count == 0, "U3 清除全部")
tool:undo()
check(slot.store.count == total, "U4 清除全部也能復原")

-- 工具列：換模式後選中的鈕仍是選中色；身上沒有的筆照樣看得出顏色（暗一點），有的照原色（2026-11-08 sketch-sp 實機）
do
    local bar, b = tool.bar, tool.bar.btns
    local function pre() bar:prerender() end
    player.items = { Pen = true, RedPen = true, ["Base.Eraser"] = true }
    tool:refreshInv()
    tool:setMode("pen")
    pre()
    tool:setMode("erase")
    pre()
    tool:setMode("line")
    pre()
    local on = b.mode.line.backgroundColor
    check(on.r > 0.2 and on.b > 0.4 and b.mode.pen.backgroundColor.r == 0, "TB1 換模式後只有目前模式是選中色")
    local blue = b.color[4].backgroundColor
    check(b.color[4].enable == false and blue.b > 0.4 and blue.a < 1, "TB2 沒有藍筆：藍色鈕停用但看得出是藍色")
    check(b.color[3].enable == true and b.color[3].backgroundColor.r > 0.6 and b.color[3].backgroundColor.a == 1,
        "TB3 有紅筆：紅色鈕原色可按")
    check(b.undo.enable == (#tool.undoStack > 0) and b.redo.enable == (#tool.redoStack > 0) and b.redo.enable == true,
        "TB4 復原／重做依堆疊啟用")
    tool:setMode("pen")
end

-- 500 點自動接成下一筆，不中斷
do
    local n3 = slot.store.count
    down(tool, 0, 0)
    for k = 1, C.MAX_STROKE_PTS + 10 do move(tool, k * 0.6, (k % 2) * 0.6) end
    up(tool)
    check(slot.store.count == n3 + 2, "P1 畫到 500 點自動接成下一筆")
end

-- 筆鈕再按一次＝關工具
Core.sketchToolStart(0)
check(Core.sketchToolOf(map) == nil, "B1 筆鈕再按一次關工具")

H.finish("test_sketch_tool")
