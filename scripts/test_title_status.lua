-- 小地圖標題列狀態（_TitleStatus.lua：registerTitleStatus）離線回歸。
-- 載入真檔，只把 PZ 全域換成假物件。核心不變量：
--   * 零註冊＝不 hook ISMiniMapTitleBar.render、不讀時鐘（標題列每幀成本與加 API 前相同）
--   * 每個標題列實例以自己的 playerNum 輪詢，250ms 快取；註冊變動立即生效
--   * 多個提供者：第一個 warn 勝出，否則註冊順序第一個非空文字
--   * 拋錯＝不畫、每個 owner 只 log 一次並停用到同 owner 再註冊（不再每 250ms 呼叫）
--   * 右半可用寬內截字加 "..."；可用寬 < 24px 整個不畫
-- 用法：lua scripts/test_title_status.lua [_TitleStatus.lua]
local path = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_TitleStatus.lua"
local file = assert(io.open(path, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()
local compile = loadstring or load

local assertions, failures = 0, 0
local function check(value, label)
    assertions = assertions + 1
    if not value then failures = failures + 1; print("FAIL " .. label) end
end
local function checkEq(actual, expected, label)
    check(actual == expected, label .. " (expected=" .. tostring(expected)
        .. ", actual=" .. tostring(actual) .. ")")
end

local CHAR_W, FONT_H = 6, 12
local function fixture()
    local t = { now = 1000, clockReads = 0, printed = {} }
    local baseRender = function() end -- 原版 ISUIElement.render（空函式）
    local TitleBar = { render = baseRender }
    t.core, t.api, t.TitleBar, t.baseRender = { ready = true }, {}, TitleBar, baseRender
    local env = setmetatable({
        MinidoracatMiniMapCore = t.core, MinidoracatMiniMapAPI = t.api,
        ISMiniMapTitleBar = TitleBar,
        getTimestampMs = function() t.clockReads = t.clockReads + 1; return t.now end,
        getTextManager = function()
            return { MeasureStringX = function(_, _, s) return #s * CHAR_W end,
                getFontHeight = function() return FONT_H end }
        end,
        UIFont = { Small = 1 },
        print = function(msg) t.printed[#t.printed + 1] = tostring(msg) end,
    }, { __index = _G })
    local chunk
    if setfenv then
        chunk = assert(compile(source, "titlestatus")); setfenv(chunk, env)
    else
        chunk = assert(load(source, "titlestatus", "t", env))
    end
    chunk()
    function t.bar(pn, width)
        local tb = setmetatable({ width = width or 300, height = 16, miniMap = { playerNum = pn },
            ops = {} }, { __index = TitleBar })
        function tb:drawText(s, x, y, r, g, b, a)
            self.ops[#self.ops + 1] = { kind = "text", s = s, x = x, y = y, r = r, g = g, b = b }
        end
        function tb:drawRect(x, y, w, h, a, r, g, b)
            self.ops[#self.ops + 1] = { kind = "rect", x = x, w = w, r = r }
        end
        return tb
    end
    function t.frame(tb)
        tb.ops = {}
        tb:render()
        return tb.ops
    end
    return t
end
local function lastText(ops)
    for i = #ops, 1, -1 do if ops[i].kind == "text" then return ops[i] end end
end

-- 一、零註冊：不 hook、不讀時鐘
do
    local t = fixture()
    checkEq(t.api.titleStatusApiVersion, 1, "Z1 版本欄位")
    check(t.TitleBar.render == t.baseRender, "Z2 零註冊不包 ISMiniMapTitleBar.render")
    local ops = t.frame(t.bar(0))
    check(#ops == 0 and t.clockReads == 0, "Z3 零註冊標題列不畫、不讀時鐘")
    check(not t.api.registerTitleStatus(nil, function() end)
        and not t.api.registerTitleStatus("", function() end)
        and not t.api.registerTitleStatus("A", "85%"), "Z4 壞參數拒收")
    check(t.TitleBar.render == t.baseRender and #t.printed == 3, "Z5 壞參數不 hook、各 log 一則")
end

-- 二、基本繪製、分割畫面 pn、快取
do
    local t = fixture()
    local calls, seen = 0, {}
    check(t.api.registerTitleStatus("Watch", function(pn)
        calls = calls + 1; seen[#seen + 1] = pn
        return pn == 0 and "85%" or "40%"
    end), "R1 註冊成功")
    check(t.TitleBar.render ~= t.baseRender, "R2 第一次註冊才包 render")
    local p0, p1 = t.bar(0), t.bar(1)
    local ops = t.frame(p0)
    local txt = lastText(ops)
    check(txt and txt.s == "85%" and txt.x == 300 - 4 - 3 * CHAR_W and txt.y == 2,
        "R3 文字靠右（右緣留 4px）且垂直置中")
    check(#ops == 1 and txt.r == 0.85, "R4 正常狀態沒有警示底色")
    checkEq(lastText(t.frame(p1)).s, "40%", "R5 每個標題列用自己的 playerNum 輪詢")
    check(seen[1] == 0 and seen[2] == 1, "R6 提供者收到 0 與 1")
    local st = p0._minidoracatTitleStatus
    for _ = 1, 5 do t.frame(p0) end
    t.now = t.now + 249
    t.frame(p0)
    check(calls == 2 and p0._minidoracatTitleStatus == st, "C1 250ms 內不重新輪詢、狀態表不重建")
    t.now = t.now + 1
    t.frame(p0)
    checkEq(calls, 3, "C2 滿 250ms 重新輪詢")
end

-- 三、警示、多提供者規則、非字串
do
    local t = fixture()
    local a, b = "85%", nil
    local bState = "warn"
    t.api.registerTitleStatus("A", function() return a end)
    t.api.registerTitleStatus("B", function() return b, bState end)
    local tb = t.bar(0)
    checkEq(lastText(t.frame(tb)).s, "85%", "M1 只有一個有文字時顯示它")
    b = "EXPIRED"
    t.api.registerTitleStatus("B", function() return b, bState end) -- 再註冊＝立即生效
    local ops = t.frame(tb)
    check(ops[1].kind == "rect" and ops[1].r == 0.55 and lastText(ops).s == "EXPIRED"
        and lastText(ops).r == 1, "W1 後註冊的警示勝過先註冊的正常，畫紅底亮字")
    check(ops[1].x == lastText(ops).x - 4 and ops[1].w == #"EXPIRED" * CHAR_W + 8,
        "W2 警示底色包住文字左右各 4px")
    bState = "normal"
    t.now = t.now + 250
    checkEq(lastText(t.frame(tb)).s, "85%", "M2 都正常時取註冊順序第一個")
    a = 85
    t.now = t.now + 250
    checkEq(lastText(t.frame(tb)).s, "EXPIRED", "M3 非字串文字當作沒有")
    b = ""
    t.now = t.now + 250
    checkEq(#t.frame(tb), 0, "M4 全部沒有文字時不畫")
end

-- 四、拋錯：不畫、log 一次並停用到再註冊（引擎 pcall 每次接錯都印堆疊，不能每 250ms 再問）
do
    local t = fixture()
    local badCalls = 0
    t.api.registerTitleStatus("Bad", function() badCalls = badCalls + 1; error("boom") end)
    local tb = t.bar(0)
    for _ = 1, 4 do
        check(#t.frame(tb) == 0, "E1 拋錯的提供者不畫")
        t.now = t.now + 250
    end
    checkEq(#t.printed, 1, "E2 同一 owner 拋錯只 log 一次")
    check(t.printed[1]:find("Bad", 1, true) ~= nil, "E3 log 帶 owner")
    checkEq(badCalls, 1, "E3b 拋錯後停用、不再每 250ms 呼叫")
    t.api.registerTitleStatus("Good", function() return "OK" end)
    checkEq(lastText(t.frame(tb)).s, "OK", "E4 其他提供者不受拋錯影響")
    t.api.registerTitleStatus("Bad", function() error("again") end)
    t.frame(tb)
    checkEq(#t.printed, 2, "E5 同 owner 再註冊重置、重新呼叫")
end

-- 五、截字與窄小地圖退化
do
    local t = fixture()
    local long = string.rep("x", 30)
    t.api.registerTitleStatus("Long", function() return long end)
    local tb = t.bar(0, 200) -- 可用寬 floor(200/2)-8 = 92px
    local txt = lastText(t.frame(tb))
    check(txt.s == string.rep("x", 12) .. "..." and #txt.s * CHAR_W <= 92,
        "T1 過長文字截成放得下的最長前綴加 ...")
    check(txt.x >= 100, "T2 截字後不進左半拖曳區")
    tb.width = 400
    checkEq(lastText(t.frame(tb)).s, long, "T3 小地圖變寬後重新截字")
    long = "85%"
    t.api.registerTitleStatus("Long", function() return long end)
    tb.width = 64 -- 可用寬 24
    checkEq(lastText(t.frame(tb)).s, "85%", "N1 可用寬 24px 仍畫短文字")
    tb.width = 63 -- 可用寬 23
    checkEq(#t.frame(tb), 0, "N2 可用寬 < 24px 整個不畫")
    long = "WWWWWW"
    t.api.registerTitleStatus("Long", function() return long end)
    tb.width = 64 -- 24px 只放得下 "..." 加 1 字（4*6=24）
    checkEq(lastText(t.frame(tb)).s, "W...", "T4 只放得下一個字時仍截字")
end

local EXPECTED_ASSERTIONS = 34
if assertions ~= EXPECTED_ASSERTIONS then
    print("assertion count mismatch: expected " .. EXPECTED_ASSERTIONS
        .. ", actual " .. assertions)
    os.exit(1)
end
print("title status assertions " .. assertions .. ", failures " .. failures)
if failures > 0 then os.exit(1) end
