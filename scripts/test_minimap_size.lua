-- 小地圖首建尺寸決策（Core.minimapSizeFor）離線回歸測試。
-- 仿 test_ghost_gate.lua：抽主檔標記區段→離線跑（純函式，只用 math.floor）。
-- 核心不變量：自訂尺寸 > 倍率縮放 > 原版尺寸；一律夾 minWH 下限——8 鈕在高字級
-- 「小（原版）」檔的溢出防護（原版 inner 寬 6*bw+72 < 8 鈕最低 8*bw+14，
-- 2x/3x/4x 字型 bw=32/39/44 各差 6/20/30px；codex review 以算術抓出的回歸）。
-- 用法：lua scripts/test_minimap_size.lua
local mainPath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap.lua"

local file = assert(io.open(mainPath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()

local body = assert(source:match(
    "%-%- test:minimap%-size:start\n(.-)\n%-%- test:minimap%-size:end"),
    "找不到 minimap-size 測試區段")

local compile = loadstring or load
local chunk = assert(compile("local Core = {}\n" .. body .. "\nreturn Core.minimapSizeFor",
    "minimap-size"))
local sizeFor = chunk()

-- S1: 原版寬足夠（1x 字級 bw≈20：6*20+72=192 ≥ min 190）→ 不動＝逐位同原版
local w, h = sizeFor(192, 192, nil, nil, 1.0, 190)
assert(w == 192 and h == 192, "S1: 原版寬足夠時不得改動（w=" .. w .. "）")

-- S2: 8 鈕回歸本尊——2x 字級 bw=32：原版 6*32+72=264 < min 270 → 抬到下限
w, h = sizeFor(264, 264, nil, nil, 1.0, 270)
assert(w == 270 and h == 270, "S2: 高字級「小」檔須抬到 8 鈕下限（w=" .. w .. "）")

-- S3: 4x 字級 bw=44：336 vs 8*44+7*2+2*2+4=374
w, h = sizeFor(336, 336, nil, nil, 1.0, 374)
assert(w == 374, "S3: 4x 字級差 30px 級距亦須補足（w=" .. w .. "）")

-- S4: 倍率縮放足夠時不夾（200×2.5=500 ≥ 270）＋四捨五入（.5 進位）
w, h = sizeFor(201, 201, nil, nil, 2.5, 270)
assert(w == 503 and h == 503, "S4: 縮放結果 math.floor(x+0.5) 四捨五入（w=" .. w .. "）")

-- S5: 縮放後仍不足 → 夾下限
w, h = sizeFor(100, 100, nil, nil, 1.5, 190)
assert(w == 190 and h == 190, "S5: 縮放後仍不足須夾下限（w=" .. w .. "）")

-- S6: 自訂尺寸優先於倍率（scale 應被忽略）
w, h = sizeFor(264, 264, 300, 240, 2.0, 190)
assert(w == 300 and h == 240, "S6: 自訂尺寸須優先於倍率（w=" .. w .. ",h=" .. h .. "）")

-- S7: 自訂尺寸低於下限也夾（getCustomSize 已夾過＝冪等；防上游夾限被繞過）
w, h = sizeFor(264, 264, 160, 500, 1.0, 190)
assert(w == 190 and h == 500, "S7: 自訂寬低於下限須夾、高足夠不動（w=" .. w .. ",h=" .. h .. "）")

print("test_minimap_size: OK（S1-S7：直通/2x/4x 補足/四捨五入/縮放夾限/自訂優先/自訂夾限）")
