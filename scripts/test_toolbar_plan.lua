-- 小地圖按鈕列收納（Core.toolbarPlan／toolbarMenuItems／toolbarMenuRun）離線回歸測試。
-- 抽主檔標記區段離線跑（純函式）。核心不變量：關閉鈕永遠在、放不下時多一顆「更多」、
-- 顯示的按鈕不超出 inner 寬、每顆可收納的按鈕恰好在按鈕列或「更多」選單其中一處。
-- 用法：lua scripts/test_toolbar_plan.lua
local mainPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"
local file = assert(io.open(mainPath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()
local body = assert(source:match("%-%- test:toolbar%-plan:start\n(.-)\n%-%- test:toolbar%-plan:end"),
    "missing toolbar-plan test block")
local Core = assert((loadstring or load)("local Core = {}\n" .. body .. "\nreturn Core", "toolbar-plan"))()

local assertions, failures = 0, 0
local function check(value, label)
    assertions = assertions + 1
    if not value then failures = failures + 1; print("FAIL " .. label) end
end

local SHORT = { button1 = "M", button2 = "-", button3 = "+", _minidoracatPerspBtn = "V",
    _minidoracatCenterBtn = "C", _minidoracatCopyBtn = "XY", _minidoracatSearchBtn = "S",
    _minidoracatHomeBtn = "H", button4 = "G", _minidoracatMoreBtn = "...", button6 = "X" }
local function allButtons(noPersp)
    local has = {}
    for name in pairs(SHORT) do has[name] = true end
    if noPersp then has._minidoracatPerspBtn = nil end
    return has
end
local BORDER = 8 -- 主檔 CHROME_BORDER：inner 寬＝外框寬 − 2×8

-- 回畫面上由左到右的按鈕、選單項目、顯示顆數
local function layout(outerW, bw, has)
    local shown, more = Core.toolbarPlan(outerW - BORDER * 2, bw, has)
    local row, count = {}, 0
    for i = 1, #Core.TOOLBAR_ORDER do
        local name = Core.TOOLBAR_ORDER[i]
        if has[name] and (shown[name] or name == "button6" or (more and name == "_minidoracatMoreBtn")) then
            count = count + 1
            row[count] = SHORT[name]
        end
    end
    local items, n = Core.toolbarMenuItems(has, shown)
    local menu = {}
    for i = 1, n do menu[i] = SHORT[items[i][1]] end
    return table.concat(row, " "), table.concat(menu, " "), count, shown, more
end

-- P1-P6: 1x 字級（bw=25）設計稿的六個寬度
local has = allButtons()
local cases = {
    { 288, "M - + V C XY S H G X", "" },
    { 257, "M - + C S H G ... X", "XY V" },
    { 240, "M C S H G ... X", "+ - XY V" }, -- 8 格只放得下「+」：放大、縮小成對收，空一格
    { 226, "M C S H G ... X", "+ - XY V" },
    { 180, "M C S G ... X", "+ - H XY V" },
    { 126, "M G ... X", "+ - C S H XY V" },
}
for i = 1, #cases do
    local row, menu = layout(cases[i][1], 25, has)
    check(row == cases[i][2], "P" .. i .. " row at " .. cases[i][1] .. " px: " .. row)
    check(menu == cases[i][3], "P" .. i .. " menu at " .. cases[i][1] .. " px: " .. menu)
end

-- P7: 視角鈕缺材質（不存在）：少一顆，260 px 就全部顯示；選單不列視角
local row, menu = layout(260, 25, allButtons(true))
check(row == "M - + C XY S H G X" and menu == "", "P7 no perspective button: all shown at 260 px: " .. row)
row, menu = layout(126, 25, allButtons(true))
check(row == "M G ... X" and menu == "+ - C S H XY", "P7 no perspective button: menu omits it: " .. menu)

-- P8: 五個字級，從最小寬（4 格）到全顯寬逐像素：最小寬恰好 4 顆；顯示的不溢出；
-- 每顆可收納的按鈕恰好在按鈕列或選單其中一處；10 顆以 2px 間距放得下（fitW）起沒有「更多」。
-- fitW 比倍率檔的下限 fullW 少 4：下限公式多留 4px，所以倍率檔一定全部顯示
for _, bw in ipairs({ 22, 25, 32, 39, 44 }) do
    local minW, fullW = 4 * bw + 26, 10 * bw + 38
    local fitW = 10 * bw + 9 * 2 + BORDER * 2
    local okFit, okOnce, okMin, okFull = true, true, true, true
    for w = minW, fullW + 40 do
        local _, _, count, shown, more = layout(w, bw, has)
        if count * bw + (count - 1) * 2 > w - BORDER * 2 then okFit = false end
        local items, n = Core.toolbarMenuItems(has, shown)
        local inMenu = {}
        for i = 1, n do inMenu[items[i][1]] = true end
        for i = 1, #Core.TOOLBAR_KEEP do
            local name = Core.TOOLBAR_KEEP[i]
            local menuable = false
            for j = 1, #Core.TOOLBAR_MENU do
                if Core.TOOLBAR_MENU[j][1] == name then menuable = true end
            end
            -- 世界地圖與設定不在選單表裡：4 格下限保證它們一定顯示
            if menuable and ((shown[name] and true or false) == (inMenu[name] and true or false)) then okOnce = false end
            if not menuable and not shown[name] then okOnce = false end
        end
        if w == minW and count ~= 4 then okMin = false end
        if w >= fitW and (more or count ~= 10) then okFull = false end
        if w < fitW and not more then okFull = false end
    end
    check(okFit, "P8 bw=" .. bw .. " shown buttons fit the inner width")
    check(okOnce, "P8 bw=" .. bw .. " every button is on the row or in the menu, never both or neither")
    check(okMin, "P8 bw=" .. bw .. " minimum width shows exactly 4 buttons")
    check(okFull and fitW <= fullW, "P8 bw=" .. bw .. " the more button appears exactly when 10 buttons do not fit")
end

-- P9: 寬到連兩格都沒有也不報錯（下限擋在前面，這裡只防算出負數），關閉鈕仍在列上
local ok, row9 = pcall(layout, 30, 25, has)
check(ok and row9:sub(-1) == "X", "P9 fewer than two slots does not error and keeps the close button")

-- P10: 選單項執行按鈕自己的動作：放大／縮小用 repeatWhilePressedFunc，其餘用 onclick；again 重開選單
local calls, reopened = {}, nil
Core.toolbarOpenMore = function(mm, at) reopened = { mm, at } end
local mm = {}
local zoom = { target = mm, onclick = function() calls[#calls + 1] = "noop" end,
    repeatWhilePressedFunc = function(target, btn) calls[#calls + 1] = target == mm and btn and "zoom" or "bad" end }
local plain = { target = mm, onclick = function(target, btn) calls[#calls + 1] = target == mm and btn and "click" or "bad" end }
Core.toolbarMenuRun(mm, zoom, 2)
check(calls[1] == "zoom" and reopened and reopened[1] == mm and reopened[2] == 2,
    "P10 zoom item runs repeatWhilePressedFunc and reopens the menu on the same row")
reopened = nil
Core.toolbarMenuRun(mm, plain, nil)
check(calls[2] == "click" and reopened == nil, "P10 other items run onclick and leave the menu closed")

-- P11: 「更多」選單的位置。參數：鈕 x, y, 高；選單寬, 高；小地圖 x, 寬；viewport 左, 上, 右, 下
local function pos(...) local x, y = Core.toolbarMenuPos(...); return x .. "," .. y end
check(pos(100, 50, 22, 150, 200, 40, 114, 0, 0, 1280, 720) == "100,72", "P11 enough room below: under the button")
check(pos(1210, 50, 22, 150, 200, 1156, 114, 0, 0, 1280, 720) == "1130,72", "P11 below: pulled inside the right edge")
check(pos(1210, 610, 22, 150, 200, 1156, 114, 0, 0, 1280, 720) == "1006,432",
    "P11 no room below: left of the mini-map, bottom on the button row")
check(pos(64, 610, 22, 150, 200, 10, 114, 0, 0, 1280, 720) == "124,432", "P11 no room on the left: right of the mini-map")
check(pos(1210, 60, 22, 150, 200, 1156, 114, 0, 0, 1280, 100) == "1006,0", "P11 beside the map: kept below the top edge")
check(pos(64, 610, 22, 150, 200, 10, 114, 0, 0, 240, 720) == "64,410", "P11 no room on either side: above the button")
check(pos(704, 250, 22, 150, 200, 650, 114, 640, 0, 1280, 360) == "764,72",
    "P11 split screen: stays inside the right-hand player viewport")

print(string.format("toolbar plan: %d assertions, %d failures", assertions, failures))
os.exit(failures == 0 and 0 or 1)
