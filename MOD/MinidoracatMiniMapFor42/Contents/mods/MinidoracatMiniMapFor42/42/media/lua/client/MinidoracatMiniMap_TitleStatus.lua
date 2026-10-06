-- MinidoracatMiniMap_TitleStatus.lua
-- 小地圖標題列狀態（titleStatusApiVersion 1）：addon 提供「已翻譯的短文字＋正常／警示」，
-- 畫在 ISMiniMapTitleBar 右半（首個消費者＝地圖錶的電量％與低電量／到期警示）。
-- 零註冊＝不 hook：標題列每幀成本與加 API 前相同；第一次註冊成功才包 ISMiniMapTitleBar.render。
-- 每個標題列實例（＝每位分割畫面玩家的小地圖）一份狀態快取，250ms 輪詢一次提供者；
-- 文字或寬度沒變時不重量測，穩態每幀不配置 table。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end
local API = MinidoracatMiniMapAPI

local TTL_MS = 250
local PAD = 4 -- 文字與右緣、警示底色與文字的間距
local MIN_W = 24 -- 右半可用寬不足（極窄小地圖）就整個不畫，不去擠拖曳區
local ELLIPSIS = "..." -- 原版字型沒有「…」（verify 字形閘門），用三個句點
local function log(msg) print("[MinidoracatMiniMap] " .. tostring(msg)) end

-- 註冊表掛 Core（測試與診斷可讀）；generation 在註冊變動時遞增，讓各標題列立即重新輪詢
Core.titleStatusProviders = {} -- { { owner=, fn=, errLogged= }, ... } 註冊順序
local generation = 0

-- 多個提供者：依註冊順序輪詢，第一個回 "warn" 的勝出；都沒有警示時取第一個非空文字。
-- 非字串或空字串＝這輪沒有狀態。拋錯＝log 一次並停用該提供者到同 owner 再註冊：
-- 引擎的 pcall 每次接到錯誤都會在 console 印整段堆疊（2026-10-06 E2E 實測，非 -debug 亦然），
-- 照常每 250ms 再問一次會洗版。
local function pollProviders(pn)
    local list = Core.titleStatusProviders
    local text = nil
    for i = 1, #list do
        local p = list[i]
        if not p.errLogged then
            local ok, t, state = pcall(p.fn, pn)
            if not ok then
                p.errLogged = true
                log("title status error (" .. p.owner .. "), disabled until re-registered: " .. tostring(t))
            elseif type(t) == "string" and t ~= "" then
                if state == "warn" then return t, true end
                if not text then text = t end
            end
        end
    end
    return text, false
end

-- 放不下就從尾端截字加 "..."（二分找最長前綴，量測只在文字或寬度改變時發生）；
-- 連一個字加 "..." 都放不下回 nil。
-- ponytail: 以字串單位截（Kahlua 為 UTF-16 code unit），罕見的代理對可能被切開；錶的文字是短 ASCII／CJK
local function fitText(text, maxW)
    local tm = getTextManager()
    if tm:MeasureStringX(UIFont.Small, text) <= maxW then return text end
    local lo, hi, best = 1, #text - 1, nil
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local s = text:sub(1, mid) .. ELLIPSIS
        if tm:MeasureStringX(UIFont.Small, s) <= maxW then best = s; lo = mid + 1 else hi = mid - 1 end
    end
    return best
end

local function drawTitleStatus(tb)
    local st = tb._minidoracatTitleStatus
    if not st then
        st = { at = 0, gen = -1, fitW = -1 } -- 每個標題列實例只建一次
        tb._minidoracatTitleStatus = st
    end
    local now = getTimestampMs()
    if st.gen ~= generation or now < st.at or now - st.at >= TTL_MS then
        st.at, st.gen = now, generation
        local mm = tb.miniMap
        local text, warn = pollProviders(mm and mm.playerNum or 0)
        st.warn = warn
        if text ~= st.text then st.text = text; st.fitW = -1 end
    end
    if not st.text then return end
    -- 右半給狀態、左半留給拖曳；寬度變了（縮放小地圖）才重新截字
    local maxW = math.floor(tb.width / 2) - PAD * 2
    if st.fitW ~= maxW then
        st.fitW = maxW
        st.shown = maxW >= MIN_W and fitText(st.text, maxW) or nil
        if st.shown then
            local tm = getTextManager()
            st.shownW = tm:MeasureStringX(UIFont.Small, st.shown)
            st.fontH = tm:getFontHeight(UIFont.Small)
        end
    end
    if not st.shown then return end
    local h = tb.height
    local x = tb.width - PAD - st.shownW
    local y = math.floor((h - st.fontH) / 2)
    if st.warn then
        tb:drawRect(x - PAD, 1, st.shownW + PAD * 2, h - 2, 0.85, 0.55, 0.08, 0.06)
        tb:drawText(st.shown, x, y, 1, 0.93, 0.85, 1, UIFont.Small)
    else
        tb:drawText(st.shown, x, y, 0.85, 0.85, 0.85, 1, UIFont.Small)
    end
end

local hooked = false
local function installHook()
    if hooked or not ISMiniMapTitleBar then return end
    hooked = true
    local originalRender = ISMiniMapTitleBar.render -- 原版繼承 ISUIElement.render（空函式）
    function ISMiniMapTitleBar:render()
        originalRender(self)
        drawTitleStatus(self)
    end
end

API.titleStatusApiVersion = 1
-- fn(playerNum) --> text[, state]；state == "warn" 為警示外觀，其他值一律正常。
-- 同 owner 再註冊＝覆蓋（錯誤旗標重置、各標題列下一幀重新輪詢）
function API.registerTitleStatus(ownerModId, fn)
    if type(ownerModId) ~= "string" or ownerModId == "" or type(fn) ~= "function" then
        log("registerTitleStatus bad arguments (need ownerModId string, fn function)")
        return false
    end
    local list = Core.titleStatusProviders
    local found = false
    for i = 1, #list do
        if list[i].owner == ownerModId then
            list[i].fn = fn
            list[i].errLogged = nil
            found = true
            break
        end
    end
    if not found then list[#list + 1] = { owner = ownerModId, fn = fn } end
    generation = generation + 1
    installHook()
    return true
end
