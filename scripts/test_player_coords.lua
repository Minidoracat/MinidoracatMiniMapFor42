-- 座標膠囊（_Nav.lua drawPlayerCoords）：世界地圖按鈕列蓋得到時改畫在按鈕列上方，蓋不到與小地圖留在底線。
local path = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Nav.lua"
local fh = assert(io.open(path, "rb"))
local source = fh:read("*a"):gsub("\r\n", "\n")
fh:close()
local body = assert(source:match("%-%- test:player%-coords:start[^\n]*\n(.-)\n%-%- test:player%-coords:end"),
    "missing player-coords test block")
local prefix = [==[
local zoom = 1
local UIFont = { Small = "Small" }
local function getTimestampMs() return 0 end
local function getBoolOption(_, default) return default end
local function getSpecificPlayer()
    return { getX = function() return 10759.5 end, getY = function() return 9770.5 end, getZ = function() return 0 end }
end
local function getTextManager()
    return { MeasureStringX = function() return 86 end, getFontHeight = function() return 16 end }
end
local function getText(key) return key end
local function mapTextZoom() return zoom end
local function drawMapText(inner, _, x, y) inner.textX, inner.textY = x, y end
]==]
local chunk, err = (loadstring or load)(prefix .. body
    .. "\nreturn { draw = drawPlayerCoords, setZoom = function(z) zoom = z end }", "@player-coords")
assert(chunk, err)
local h = chunk()
local assertions, failures = 0, 0
local function check(value, label)
    assertions = assertions + 1
    if not value then failures = failures + 1; print("FAIL " .. label) end
end
-- 回膠囊底框 {x, y, w, h}
local function pill(w, hgt, row, copiedUntil, freelook, icon)
    local inner = { width = w, height = hgt, buttonPanel = row, _minidoracatCopiedUntil = copiedUntil,
        _minidoracatFreelook = freelook, _minidoracatFreelookIcon = icon,
        drawRect = function(self, x, y, rw, rh) self.rect = { x, y, rw, rh } end }
    h.draw(inner)
    return inner.rect
end
local function rowOf(w, hgt, rowW) return { x = w - 10 - rowW, y = hgt - 10 - 48, width = rowW, height = 48 } end
local function hits(r, row)
    return r[1] < row.x + row.width and row.x < r[1] + r[3] and r[2] < row.y + row.height and row.y < r[2] + r[4]
end

-- C1: 1920 寬、860 px 按鈕列：膠囊在按鈕列左邊，留在底線
local row = rowOf(1920, 1080, 860)
local r = pill(1920, 1080, row)
check(r[2] == 1080 - 16 - 10 - 3 and not hits(r, row), "C1 wide window keeps the pill on the bottom line")
-- C2: 1280、1366、1600 寬：膠囊不得落在按鈕列矩形內，改到按鈕列上方、仍置中
for _, w in ipairs({ 1280, 1366, 1600 }) do
    row = rowOf(w, 720, 860)
    r = pill(w, 720, row)
    check(not hits(r, row), "C2 pill clear of the button row at width " .. w)
    check(r[2] + r[4] <= row.y and r[1] + r[3] / 2 == w / 2, "C2 pill above the row and centred at width " .. w)
end
-- C3: 文字倍率放大後 1920 寬也會碰到（膠囊變寬）：一樣移上去
h.setZoom(3)
row = rowOf(1920, 1080, 871)
r = pill(1920, 1080, row)
check(not hits(r, row) and r[2] + r[4] <= row.y, "C3 wider pill moves above the row at 1920")
h.setZoom(1)
-- C4: 小地圖（沒有 buttonPanel）照舊在底線
r = pill(323, 323, nil)
check(r[2] == 323 - 16 - 10 - 3, "C4 minimap pill stays on the bottom line")
-- C5: 迷你尺寸的小地圖放不下（文字 86＋左右各 8 > 100）：不畫，免得膠囊畫出小地圖外
check(pill(100, 100, nil) == nil, "C5 pill is skipped when wider than a mini-sized minimap")
check(pill(102, 102, nil) ~= nil, "C5 pill is drawn when it just fits")
-- C6: 「已複製」是按了複製才有的回饋，放不下也照畫
check(pill(60, 60, nil, 1) ~= nil, "C6 copied feedback is always drawn")
-- C7: 自由查看的提示在底線時座標列讓到上面；提示縮成左上角圖示（迷你尺寸）時留在底線
check(pill(323, 323, nil, nil, true)[2] == 323 - 16 - 10 - 3 - 26, "C7 pill moves above the free-look hint")
check(pill(114, 114, nil, nil, true, true)[2] == 114 - 16 - 10 - 3, "C7 pill stays on the bottom line with the icon hint")

print(string.format("player coords: %d assertions, %d failures", assertions, failures))
os.exit(failures == 0 and 0 or 1)
