-- 地圖顯示設定視窗（_Settings.lua）離線回歸：真的 UI 框架 rev 17 元件＋真的 _Settings／_Markers，
-- 地圖畫法 helper 從各模組原始碼抽出（見 scripts/settings_harness.lua）。缺同層框架 repo＝FAIL（不是 SKIP）。
-- 範圍：框架缺席／過舊只提示不開窗；四組側欄與群組內順序；自訂區域／MOD 地圖有條件出現；管理員組；
-- 沙盒閘停用開關＋提示；顯示距離上限；搜尋布林與跳轉；被世界地圖蓋住置頂；分割畫面換擁有者；
-- 開窗重讀現值；重設；效果預覽用地圖畫法畫得出來；手把接手與 B 回小地圖；版面在 viewport 內。
local H = dofile("scripts/settings_harness.lua")
local assertions, failures = 0, 0
local function check(value, label)
    assertions = assertions + 1
    if not value then failures = failures + 1; io.write("FAIL " .. label .. "\n") end
end
local function checkEq(actual, expected, label)
    check(actual == expected, label .. " (expected=" .. tostring(expected) .. ", actual=" .. tostring(actual) .. ")")
end
if not H.frameworkPresent() then
    io.write("FAIL test_settings_studio: UI framework not found (clone MinidoracatUIFor42 beside this repo or set MUI_LUA)\n")
    os.exit(1)
end
local T = function(key) return getText(key) end

local function navRows(nav)
    nav:prerender() -- 套用 refresh() 的重讀
    local rows = {}
    for _, row in ipairs(nav._rows) do rows[#rows + 1] = row end
    return rows
end
local function navRow(nav, id)
    for _, row in ipairs(navRows(nav)) do
        if row.id == id then return row end
    end
end
local function findControl(env, pred)
    local list = env.controls(pred)
    return list[1]
end
local function byLabel(env, label)
    return findControl(env, function(el) return el.label == label or el.title == label end)
end
local function typed(env, typeName)
    return env.controls(function(el) return env.type(el) == typeName end)
end
local function textShown(env, text)
    return findControl(env, function(el)
        if not el._lines then return false end
        for _, l in ipairs(el._lines) do if l:find(text, 1, true) then return true end end
        return false
    end) ~= nil
end

-- ── A 框架缺席／過舊：每按一次提示一次、不開任何視窗 ────────────────────────────
do
    local env = H.load{ framework = false }
    env.boot()
    env.Core.toggleSettingsWindow(env.minimap(0))
    env.Core.toggleSettingsWindow(env.minimap(0))
    checkEq(#env.halo, 2, "A1 missing framework: one halo notice per click")
    checkEq(env.halo[1], T("UI_MinidoracatMiniMap_NeedFramework"), "A1 notice text is the NeedFramework key")
    check(env.Core.settingsWindow() == nil, "A2 missing framework opens nothing")
    check(env.halo[1]:find("ESC", 1, true) ~= nil, "A2 notice points players to ESC options")

    local old = H.load{ framework = "old" }
    old.boot()
    old.Core.toggleSettingsWindow(old.minimap(0))
    checkEq(#old.toasts, 1, "A3 rev 16 framework: notice goes through UI.Toast")
    checkEq(old.toasts[1] and old.toasts[1].message, T("UI_MinidoracatMiniMap_NeedFramework"), "A3 toast message")
    checkEq(#old.halo, 0, "A3 toast path does not also add a halo note")
    check(old.Core.settingsWindow() == nil, "A4 rev 16 framework opens nothing")
    -- 地圖本身 fail-soft：載入不拋錯、公開 API 仍在
    checkEq(old.API.settingsApiVersion, 5, "A5 registry still loads without the new window")
end

-- ── B 視窗外框、四組側欄、群組內順序 ───────────────────────────────────────────
local env = H.load{}
env.boot()
local s = env.open(0)
local win = s.win
check(win:isVisible(), "B1 gear opens the window")
checkEq(win.title, T("UI_MinidoracatMiniMap_StudioTitle"), "B1 window title")
check(win.closable == true and win.pinButton == nil and win.collapseButton == nil,
    "B2 close button only (no pin/collapse)")
checkEq(env.type(win), "MinidoracatUIWindow", "B2 window is UI.Window")
checkEq(table.concat(s.sections, ","), "base,places,poicat,zombie,animals,vehicles,safehouse,window,perf",
    "B3 built-in categories in fixed order without addons")
do
    local headers, items = {}, {}
    for _, row in ipairs(navRows(s.nav)) do
        if row.header then headers[#headers + 1] = row.title else items[#items + 1] = row end
    end
    checkEq(table.concat(headers, "|"), T("UI_MinidoracatMiniMap_GroupLayers") .. "|" .. T("UI_MinidoracatMiniMap_GroupWindow"),
        "B4 only non-empty group headers (layers, window)")
    local icons = {}
    for _, row in ipairs(items) do icons[#icons + 1] = row.id .. "=" .. tostring(row.icon) end
    checkEq(table.concat(icons, ","), "base=layers,places=markerFlag,poicat=pin,zombie=skull,animals=pawprint,"
        .. "vehicles=steeringwheel,safehouse=house,window=sliders,perf=chart", "B5 nav icons per category")
    local switches = {}
    for _, row in ipairs(items) do if row.switch then switches[#switches + 1] = row.id end end
    checkEq(table.concat(switches, ","), "poicat,zombie,animals,vehicles,safehouse", "B6 master switches in nav")
end
check(win.x >= 0 and win.y >= 0 and win.x + win.width <= 1920 and win.y + win.height <= 1080,
    "B7 window stays inside the owner's viewport")
checkEq(s.pane, "wide", "B7 wide viewport shows nav and inspector side by side")
check(s.navScroll.visible and s.inspector.visible and s.nav.parent == s.navScroll,
    "B8 nav sits inside a ScrollPanel next to the inspector")
-- 焦點順序：搜尋 → 導覽 → inspector 控制項（閱讀順序）→ 重設
do
    local targets = env.UI.Focus.collectTargets(win)
    local first = targets[1] and (targets[1].control or targets[1].controls and targets[1].controls[1])
    local second = targets[2] and (targets[2].control or targets[2].controls and targets[2].controls[1])
    local last = targets[#targets] and (targets[#targets].control or targets[#targets].controls[1])
    local firstFrame = targets[1] and (targets[1].frame or first)
    check(firstFrame == s.search and second == s.nav, "B9 focus order starts search -> nav")
    check(last and last._sec and last.title == T("UI_MinidoracatMiniMap_StudioResetCategory"),
        "B9 focus order ends on reset")
end

-- ── D 主開關、勾選、下拉、滑條（每種控制項各一）＋導覽同步 ─────────────────────────
s.selectSection("zombie")
do
    local header = env.controls(function(el) return el._sec and el._sec.id == "zombie" and env.type(el) == "MinidoracatUICheckbox" end)[1]
    check(header ~= nil and header.checked == false, "D1 zombie header switch mirrors ZombieDots (off)")
    local applies = env.applies
    header:forceClick()
    checkEq(env.values.ZombieDots, true, "D1 header switch writes ZombieDots")
    check(env.applies > applies, "D1 header switch applies options")
    check(navRow(s.nav, "zombie").on == true, "D2 nav switch follows the header (nav:refresh)")
    navRow(s.nav, "zombie").switch.set(false)
    env.frame()
    header = env.controls(function(el) return el._sec and el._sec.id == "zombie" and env.type(el) == "MinidoracatUICheckbox" end)[1]
    check(env.values.ZombieDots == false and header.checked == false, "D2 nav switch rebuilds the header")
    local wm = env.byKey("WMZombieDots")
    checkEq(wm.label, T("UI_MinidoracatMiniMap_WMZombieDots"), "D3 world-map tick lives in the zombie category")
    checkEq(wm.tooltip, T("UI_MinidoracatMiniMap_WM_tooltip"), "D3 world-map tick carries the ESC tooltip")
    wm:forceClick()
    checkEq(env.values.WMZombieDots, true, "D3 world-map tick writes its option")
    checkEq(env.byKey("ZombieIntensity").tooltip, T("UI_MinidoracatMiniMap_ZombieIntensity_tooltip"),
        "D4 checkbox tooltip = <label>_tooltip from ESC")
    local dd = env.byKey("ZombieDotColor")
    checkEq(env.type(dd), "MinidoracatUIDropdown", "D5 combos are UI.Dropdown")
    dd:setSelected(3)
    checkEq(env.values.ZombieDotColor, 3, "D5 dropdown writes combo index")
    local row = env.byKey("ZombieDotSize")
    checkEq(env.type(row), "MinidoracatUISliderRow", "D6 sliders are UI.SliderRow")
    local saves = env.saves
    env.mouseDown = true
    row:setValue(7)
    checkEq(env.values.ZombieDotSize, 7, "D6 slider writes the in-memory value while dragging")
    env.frame()
    checkEq(env.saves, saves, "D6 no file save while the mouse is held")
    env.mouseDown = false
    env.frame()
    checkEq(env.saves, saves + 1, "D6 one save after release")
    -- 控制項順序：標題 → 預覽 → 開關 → 樣式 → 大小 → 距離 → 重設
    local order = {}
    for _, el in ipairs(env.studio().controls) do
        local t = env.type(el)
        if t == "MinidoracatUIPreview" then order[#order + 1] = "preview"
        elseif el._findKey == "WMZombieDots" then order[#order + 1] = "tick"
        elseif el._findKey == "ZombieDotColor" then order[#order + 1] = "combo"
        elseif el._findKey == "ZombieDotSize" then order[#order + 1] = "size"
        elseif el._findKey == "ClientZombieDotDistance" then order[#order + 1] = "distance"
        elseif el._sec and t == "MinidoracatUIButton" then order[#order + 1] = "reset" end
    end
    checkEq(table.concat(order, ","), "preview,tick,combo,size,distance,reset", "D7 inspector control order")
end

-- ── E 伺服器沙盒閘：開關停用＋橘字提示；不相干的勾選照常 ─────────────────────────
env.gates.AllowZombieDots = false
env.frame()
do
    check(navRow(s.nav, "zombie").swEn == false, "E1 gated nav switch disabled (switch.enabled)")
    local header = env.controls(function(el) return el._sec and el._sec.id == "zombie" and env.type(el) == "MinidoracatUICheckbox" end)[1]
    check(header and header._enabled == false, "E2 gated header switch disabled")
    check(textShown(env, T("UI_MinidoracatMiniMap_ServerDisabled")), "E3 inspector shows ServerDisabled note")
    check(env.byKey("WMZombieDots")._enabled == false, "E4 gated world-map tick disabled")
    check(env.byKey("ZombieIntensity")._enabled == true, "E4 ungated heat-map tick stays enabled")
    checkEq(env.lastGatePn, 0, "E5 gates read for the owning player slot")
end
env.gates.AllowZombieDots = nil
env.frame()

-- ── F 顯示距離：0＝不限、伺服器上限顯示且不寫回存值 ─────────────────────────────
env.values.ClientZombieDotDistance = 1500
env.dists.ZombieDotDistance = 300
s.rebuild()
do
    local row = env.byKey("ClientZombieDotDistance")
    row:prerender()
    checkEq(row._capNow, 300, "F1 distance slider capped by the server value")
    checkEq(row._slider.max, 300, "F1 capped slider maximum")
    checkEq(env.values.ClientZombieDotDistance, 1500, "F2 cap never rewrites the stored value")
    checkEq(row.tooltip, T("UI_MinidoracatMiniMap_DistNote"), "F3 distance slider explains value/server cap")
    env.values.ClientZombieDotDistance = 0
    s.rebuild()
    row = env.byKey("ClientZombieDotDistance")
    row:prerender()
    check(row._text and row._text:find(T("UI_MinidoracatMiniMap_DistUnlimited"), 1, true)
        and row._text:find("300", 1, true), "F4 0 reads as unlimited plus the cap (" .. tostring(row._text) .. ")")
    env.dists.ZombieDotDistance = nil
    row:prerender()
    checkEq(row._capNow, nil, "F5 cap function is polled live (removed cap)")
end

-- ── G 分類內容：世界地圖勾選搬進三類、ZombieIntensity 在殭屍、距離在各類、引擎勾選在底圖 ──
do
    local expect = {
        base = { "MapImagery", "PlaceNames", "StreetNames", "TextAnnotations", "ChunkGrid", "ChunkGridLabels",
            "Isometric", "Symbols", "RemoteSymbols", "MapTextScale" },
        places = { "Players", "Places", "NavRoute", "KeepFinishedTrip", "MarkerIconSize" },
        poicat = { "PoiBlocks", "PoiWholeBuilding", "PoiColorIcons", "Cat:military", "PoiIconSize", "PoiIconAlpha",
            "ClientPoiDisplayDistance" },
        animals = { "AnimalWild", "AnimalLivestock", "WMAnimalWild", "WMAnimalLivestock", "AnimalSpeciesFilter:deer",
            "AnimalIconStyle", "AnimalIconSize", "AnimalNames", "AnimalNameDistance", "ClientAnimalIconDistance" },
        vehicles = { "WMVehicleDots", "VehicleCategoryFilter:heavy", "VehicleIconColor", "VehicleIconSize",
            "ClientVehicleIconDistance" },
        safehouse = { "Safehouses", "SafehouseIcons", "SafehouseNames", "SafehouseIconSize",
            "ClientSafehouseDisplayDistance", "ClientSafehouseNameDistance" },
        window = { "LockPosition", "FreeLook", "GhostMode", "FloatIcon", "MapSize", "AdornMode", "Opacity",
            "GhostAlpha", "ResetSize" },
    }
    for id, keys in pairs(expect) do
        s.selectSection(id)
        for _, key in ipairs(keys) do
            check(env.byKey(key) ~= nil, "G1 " .. id .. " shows " .. key)
        end
    end
    s.selectSection("base")
    check(env.byKey("RemotePlayers") == nil, "G2 RemotePlayers hidden in single player")
    s.selectSection("places")
    check(env.byKey("RemotePlayers") == nil and env.byKey("SharedTargets") == nil, "G2 MP-only ticks hidden in SP")
    -- 引擎勾選直寫 mapAPI，重設不動
    s.selectSection("base")
    env.byKey("Isometric"):forceClick()
    checkEq(env.engine[0].Isometric, true, "G3 engine tick writes the owner's map API")
    env.values.MapImagery = false
    local reset = findControl(env, function(el) return el._sec and el.title == T("UI_MinidoracatMiniMap_StudioResetCategory") end)
    reset.onclick(reset.target, reset)
    checkEq(env.values.MapImagery, true, "G4 reset restores ModOptions defaults")
    checkEq(env.engine[0].Isometric, true, "G4 reset keeps engine options")
    -- 小地圖視窗：恢復預設尺寸清 CustomSize 並 apply
    s.selectSection("window")
    env.values.CustomSize = "500x400"
    local applies = env.applies
    local rs = env.byKey("ResetSize")
    checkEq(rs.title, T("UI_MinidoracatMiniMap_ResetSize"), "G5 window category has the reset-size button")
    checkEq(rs.tooltip, T("UI_MinidoracatMiniMap_ResetSize_tooltip"), "G5 reset-size tooltip")
    rs.onclick(rs.target, rs)
    check(env.values.CustomSize == "" and env.applies == applies + 1, "G5 reset size clears CustomSize and applies")
    -- PlaceNames 連動 Symbols：勾選後下一幀重建（引擎勾選重讀）
    s.selectSection("base")
    local before = env.byKey("Symbols")
    env.engine[0].Symbols = true
    env.byKey("PlaceNames"):forceClick()
    env.frame()
    check(env.byKey("Symbols") ~= before and env.byKey("Symbols").checked == true, "G6 PlaceNames rebuilds the engine ticks")
end

-- ── H 篩選 chip：POI 類別、物種 CSV、全選／全不選 ───────────────────────────────
do
    s.selectSection("poicat")
    local chip = env.byKey("Cat:food")
    checkEq(chip.style, "chip", "H1 filters are chip buttons")
    check(chip:isActive() and chip.icon ~= nil, "H1 POI chip active with its category icon")
    chip.onclick(chip.target, chip)
    check(env.values.Cat_food == false and not chip:isActive(), "H2 POI chip writes Cat_ option")
    local none = byLabel(env, T("UI_MinidoracatMiniMap_SelectNone"))
    none.onclick(none.target, none)
    checkEq(env.values.Cat_military, false, "H3 select none clears every category")
    env.frame()
    check(not env.byKey("Cat:military"):isActive(), "H3 chips rebuilt after select none")
    s.selectSection("animals")
    local deer = env.byKey("AnimalSpeciesFilter:deer")
    deer.onclick(deer.target, deer)
    checkEq(env.values.AnimalSpeciesFilter, "deer", "H4 species chip writes the CSV filter")
    local all = byLabel(env, T("UI_MinidoracatMiniMap_SelectAll"))
    all.onclick(all.target, all)
    checkEq(env.values.AnimalSpeciesFilter, "-", "H4 select all writes the empty sentinel")
    s.selectSection("vehicles")
    check(byLabel(env, T("UI_MinidoracatMiniMap_SelectNone")) ~= nil, "H5 vehicle categories also get select all/none")
end

-- ── I 牲畜模式 4、安全屋沙盒模式 1 ─────────────────────────────────────────────
do
    env.livestockMode = 4
    env.frame()
    s.selectSection("animals")
    check(env.byKey("AnimalLivestock")._enabled == false and env.byKey("WMAnimalLivestock")._enabled == false,
        "I1 livestock mode 4 disables livestock ticks")
    check(textShown(env, T("UI_MinidoracatMiniMap_LivestockHiddenBySandbox")), "I1 livestock note")
    env.livestockMode = 1
    env.frame()
    env.safehouseNameMode = 1
    s.selectSection("safehouse")
    check(env.byKey("SafehouseNames")._enabled == false and env.byKey("Safehouses")._enabled == true,
        "I2 safehouse name mode 1 disables only the names tick")
    check(textShown(env, T("UI_MinidoracatMiniMap_SafehouseNamesHiddenBySandbox")), "I2 safehouse sandbox note")
    env.safehouseNameMode = nil
end

-- ── J 效果預覽：每個圖層分類頂端都有，畫法來自地圖 helper，現值即時反映 ─────────────
do
    local function previewOf(id)
        s.selectSection(id)
        local pv = typed(env, "MinidoracatUIPreview")[1]
        if pv then pv.draws = {}; pv:prerender() end
        return pv
    end
    local function count(pv, kind, pred)
        local n = 0
        for _, d in ipairs(pv.draws) do if d.kind == kind and (not pred or pred(d)) then n = n + 1 end end
        return n
    end
    for _, id in ipairs({ "places", "poicat", "zombie", "animals", "vehicles", "safehouse" }) do
        local pv = previewOf(id)
        check(pv ~= nil, "J1 " .. id .. " has a preview")
        check(pv and not pv._failed, "J1 " .. id .. " preview draws without error")
    end
    for _, id in ipairs({ "base", "window", "perf" }) do
        check(previewOf(id) == nil, "J2 no preview on " .. id)
    end
    env.values.ZombieDotColor = 2
    env.values.ZombieDotSize = 5
    local pv = previewOf("zombie")
    check(count(pv, "rect", function(d) return d[3] == 5 and d[6] == 1.0 and d[7] == 0.9 end) == 9,
        "J3 zombie preview draws 9 dots with the chosen colour and size (drawZombieDot)")
    env.values.AnimalNames = true
    env.values.AnimalIconStyle = 2
    pv = previewOf("animals")
    check(count(pv, "tex", function(d) return type(d[1]) == "table" and d[1].item ~= nil end) == 2,
        "J4 animal preview follows the item style")
    check(count(pv, "text", function(d) return d[1] == T("UI_MinidoracatMiniMap_Sp_Deer") end) == 1,
        "J4 animal names drawn when AnimalNames is on")
    env.values.AnimalNames = false
    pv = previewOf("animals")
    checkEq(count(pv, "text"), 0, "J4 names off = no labels")
    env.values.SafehouseNames = false
    pv = previewOf("safehouse")
    check(count(pv, "line") == 4 and count(pv, "text") == 0, "J5 safehouse preview: rectangle, no name when off")
    env.values.Places = false
    pv = previewOf("places")
    checkEq(#pv.draws > 0 and count(pv, "tex"), 0, "J6 places preview hides markers when Places is off")
    env.values.Places = nil
    pv = previewOf("places")
    check(count(pv, "text", function(d) return d[1] == T("UI_MinidoracatMiniMap_PlaceHome") end) == 1,
        "J6 places preview draws the home label (drawPlaceAt)")
    -- 零配置：預覽繪製函式本身不建 table／closure（原始碼守衛：繪製段不得出現 `{` 或 function）
    local src = H.readFile(H.SETTINGS)
    for _, name in ipairs({ "previewZombie", "previewAnimals", "previewVehicles", "previewPoi", "previewSafehouse",
        "previewPlaces", "previewZones", "previewLayer" }) do
        local body = src:match("\nlocal function " .. name .. "%(.-\nend\n")
        check(body and not body:find("{", 1, true) and not body:find("function%(", 10),
            "J7 " .. name .. " allocates nothing per frame")
    end
end

-- ── K 搜尋：布林結果可直接切（受閘門）、其餘跳到分類並清空搜尋、無結果提示 ─────────
do
    local search = s.search
    search._entry:setText("  CHUNK  ")
    search:prerender()
    env.frame()
    local results = env.controls(function(el) return el._hit ~= nil end)
    check(#results > 0, "K1 search lists results across categories")
    search._entry:setText(T("UI_MinidoracatMiniMap_WMZombieDots"))
    search:prerender()
    env.gates.AllowZombieDots = false
    env.frame()
    local box = findControl(env, function(el) return el._hit and el._hit.entry and el._hit.entry.id == "WMZombieDots" end)
    check(box and env.type(box) == "MinidoracatUICheckbox", "K2 boolean result is a checkbox")
    check(box and box._enabled == false and box.label:find(T("UI_MinidoracatMiniMap_ServerDisabled"), 1, true),
        "K2 gated boolean result disabled with the server note")
    env.gates.AllowZombieDots = nil
    env.frame()
    box = findControl(env, function(el) return el._hit and el._hit.entry and el._hit.entry.id == "WMZombieDots" end)
    local was = env.values.WMZombieDots
    box:forceClick()
    checkEq(env.values.WMZombieDots, not was, "K3 boolean result writes the option")
    search._entry:setText(T("UI_MinidoracatMiniMap_DistVehicle"))
    search:prerender()
    env.frame()
    local nav = findControl(env, function(el) return el._hit and el._hit.kind == "navigate" end)
    check(nav and env.type(nav) == "MinidoracatUIButton", "K4 navigate result is a button")
    nav.onclick(nav.target, nav)
    env.frame()
    local st = env.studio()
    checkEq(st.selected, "vehicles", "K4 navigate jumps to the category")
    checkEq(search:getText(), "", "K4 navigate clears the search")
    check(env.byKey("ClientVehicleIconDistance") ~= nil, "K4 target control is in the inspector")
    search._entry:setText("zzzz-no-such-setting")
    search:prerender()
    env.frame()
    check(textShown(env, T("UI_MinidoracatMiniMap_StudioNoResults")), "K5 no-results text")
    search._entry:setText("")
    search:prerender()
    env.frame()
end

-- ── L 開關入口：同玩家再按＝關；被世界地圖蓋住＝置頂不關；分割畫面換擁有者；開窗重讀現值 ──
do
    env.values.ZombieDots = true
    env.Core.toggleSettingsWindow(env.minimap(0))
    check(not win:isVisible(), "L1 same player toggle closes")
    env.open(0)
    check(win:isVisible(), "L2 reopen")
    s = env.studio()
    s.selectSection("zombie")
    local header = env.controls(function(el) return el._sec and env.type(el) == "MinidoracatUICheckbox" end)[1]
    check(header.checked == true, "L2 opening rebuilds from current ModOptions values")
    env.behindWorldMap = 0
    local top = win.broughtToTop
    env.Core.toggleSettingsWindow(env.minimap(0))
    check(win:isVisible() and win.broughtToTop ~= top, "L3 covered by own world map: bring to top, not close")
    env.behindWorldMap = nil
    env.Core.toggleSettingsWindow(env.minimap(1))
    s = env.studio()
    check(win:isVisible() and win._playerNum == 1, "L4 other split-screen player re-owns the window")
    check(win.x >= 960 and win.x + win.width <= 1920 or win.width > 960, "L4 re-owned window moves into P1's viewport")
    s.selectSection("base")
    env.byKey("Isometric"):setChecked(not env.byKey("Isometric").checked)
    check(env.engine[1].Isometric ~= nil and env.engine[0].Isometric == true, "L5 engine writes go to the owner's minimap")
    env.Core.toggleSettingsWindow(env.minimap(1))
    check(not win:isVisible(), "L6 owner toggles it closed")
end

-- ── M 管理員組：資格三鑰匙、本機旗標、隱私子開關 ───────────────────────────────
do
    env.policy.can, env.policy.allowTactical = true, true
    s = env.open(0)
    checkEq(s.sections[#s.sections], "admin", "M1 eligible admin gets the admin category last")
    local last
    for _, row in ipairs(navRows(s.nav)) do if row.header then last = row.title end end
    checkEq(last, T("UI_MinidoracatMiniMap_GroupAdmin"), "M1 admin group header")
    checkEq(navRow(s.nav, "admin").icon, "shieldCheck", "M1 admin icon")
    s.selectSection("admin")
    local tactical = env.byKey("AdminTactical")
    local privacy = findControl(env, function(el) return el.label == T("UI_MinidoracatMiniMap_AdminPrivacy") end)
    check(privacy._enabled == false, "M2 privacy disabled until tactical is on and allowed")
    check(textShown(env, T("UI_MinidoracatMiniMap_AdminPrivacyDisabled")), "M2 privacy-not-allowed note")
    tactical:forceClick()
    check(env.policy.tactical == true and env.policy.lastPn == 0, "M3 tactical writes the owner's local flag")
    env.policy.allowTactical = false
    env.frame()
    check(table.concat(env.studio().sections, ","):find("admin") == nil, "M4 revoked policy removes admin live")
    env.policy.can, env.policy.allowTactical = false, false
    env.Core.toggleSettingsWindow(env.minimap(0))
end

-- ── P OnGameStart 銷毀單例；源碼守衛：舊 ISUI 視窗與私有斷行已刪 ───────────────────
do
    env.open(0)
    env.start()
    check(env.Core.settingsWindow() == nil and not win.inUIManager, "P1 OnGameStart destroys the singleton")
    local src = H.readFile(H.SETTINGS)
    for _, gone in ipairs({ "ISCollapsableWindow", "ISTickBox", "ISComboBox", "ISSliderPanel", "ISTextEntryBox",
        "wrapCut", "studioBuildNav", "studioAddMasterPill", "unifiedAddWrappedNote", "ADDON_SLIDER_METHODS",
        "addonSliderSetValue" }) do
        check(not src:find(gone, 1, true), "P2 old window code removed: " .. gone)
    end
    check(src:find("UI.Text.wrap", 1, true) ~= nil, "P3 notes wrap through UI.Text.wrap")
    -- 主 chunk 字面值 ASCII-only（Kahlua 截非 ASCII 字面值）
    local bad
    for line in src:gmatch("[^\n]+") do
        local code = line:gsub("%-%-.*$", "")
        for lit in code:gmatch('"([^"]*)"') do
            if lit:find("[\128-\255]") then bad = lit end
        end
    end
    check(bad == nil, "P4 Lua string literals are ASCII only (" .. tostring(bad) .. ")")
end

-- 以下各段自建環境（全域會換成新環境的假物件），主環境 env 之後不再使用
-- ── C 窄 viewport：單頁＋返回分類 ─────────────────────────────────────────────
do
    local e = H.load{}
    e.viewports[0] = { 0, 0, 520, 700 }
    e.boot()
    local st = e.open(0)
    checkEq(st.pane, "narrow", "C1 narrow viewport falls back to one pane")
    check(st.navScroll.visible and not st.inspector.visible, "C1 narrow starts on the category list")
    check(st.win.width <= 512, "C1 narrow window fits the viewport")
    st.nav.onSelect(st.nav.target, "zombie", st.nav)
    e.frame()
    st = e.studio()
    check(not st.navScroll.visible and st.inspector.visible, "C2 selecting a category opens its page")
    local back = byLabel(e, T("UI_MinidoracatMiniMap_StudioBack"))
    check(back ~= nil, "C2 narrow page has a back button")
    back.onclick(back.target, back)
    e.frame()
    st = e.studio()
    check(st.navScroll.visible and not st.inspector.visible, "C3 back returns to the category list")
    checkEq(st.nav:getSelected(), nil, "C4 list page marks no selection")
    st.nav:setSelected("zombie") -- 同一個分類再點一次也要打開（NavList 只在選取改變時回呼）
    e.frame()
    st = e.studio()
    check(st.inspector.visible and st.selected == "zombie", "C4 re-picking the last category opens it again")
end

-- ── N 自訂區域／MOD 地圖只在有 provider／地圖包時出現（擴充功能組 order 1／2）────────
do
    local e = H.load{}
    e.Core.registeredZoneProviders[1] = { owner = "Zones", internal = false, optionKey = "ZonesExtra",
        optionLabelKey = "ZonesExtraLabel", fn = function() return { { name = "Base", icon = { tex = {}, r = 1, g = 1, b = 1 },
            rects = {} } } end }
    e.Core.registeredPacks[1] = { id = "pack" }
    e.Core.registeredZoneActions[1] = { labelKey = "UI_MinidoracatMiniMapZones_GenTemplate",
        options = { { labelKey = "A", value = "a" }, { labelKey = "B", value = "b" } },
        onTrigger = function(v) e.triggered = v end }
    e.zoneCats = { "farm", "loot" }
    e.boot()
    local st = e.open(0)
    checkEq(table.concat(st.sections, ","), "base,places,poicat,zombie,animals,vehicles,safehouse,window,perf,zones,mappack",
        "N1 zones (order 1) then map packs (order 2) in the add-on group")
    checkEq(navRow(st.nav, "zones").icon, "zone", "N1 zones icon")
    check(navRow(st.nav, "zones").switch ~= nil and navRow(st.nav, "mappack").switch == nil, "N1 zones nav switch = ZoneLayer")
    st.selectSection("zones")
    for _, key in ipairs({ "ZonesExtra", "ZoneCategoryFilter:farm", "ZoneIconSize", "ZoneNames", "ZoneNamesFar",
        "ClientZoneDisplayDistance", "zoneAction:1" }) do
        check(e.byKey(key) ~= nil, "N2 zones shows " .. key)
    end
    local pv = typed(e, "MinidoracatUIPreview")[1]
    pv:prerender()
    check(pv and not pv._failed, "N3 zones preview draws (drawZoneIcon/drawZoneName)")
    local dd = e.controls(function(el) return el._action ~= nil and e.type(el) == "MinidoracatUIDropdown" end)[1]
    dd:setSelected(2)
    local btn = e.byKey("zoneAction:1")
    btn.onclick(btn.target, btn)
    checkEq(e.triggered, "b", "N4 zone action row = Dropdown + Button with the picked value")
    st.selectSection("mappack")
    check(e.byKey("MapPackLayers") and e.byKey("MapBounds") and e.byKey("MapBoundsColor") and e.byKey("MapBoundsAlpha"),
        "N5 map-pack options live in the MOD maps category")
    local none = H.load{}
    none.boot()
    local ns = none.open(0)
    check(not table.concat(ns.sections, ","):find("zones") and not table.concat(ns.sections, ","):find("mappack"),
        "N6 no provider / no packs = no zones / mappack")
end

-- ── O 手把：擁有者在用手把才接手；B 關窗、焦點回小地圖；鍵盤焦點時不漏鍵 ─────────────
do
    local e = H.load{}
    e.boot()
    local mm = e.minimap(0)
    e.joypads[0] = { id = 0, focus = mm }
    JoypadState.players[1] = e.joypads[0]
    local st = e.open(0)
    check(e.joypads[0].focus == st.win, "O1 joypad owner: window takes joypad focus")
    e.UI.Focus.onJoypadDown(st.win, Joypad.BButton, e.joypads[0])
    check(not st.win:isVisible(), "O2 B closes the window")
    check(e.joypads[0].focus == mm, "O2 focus returns to the player's minimap")
    -- 原焦點已不在畫面上：仍回到自己的小地圖
    mm.visible = true
    e.joypads[0].focus = nil
    st = e.open(0)
    e.joypads[0].focus = st.win
    st.win._focusJoyRestore = nil
    e.UI.Focus.onJoypadDown(st.win, Joypad.BButton, e.joypads[0])
    check(e.joypads[0].focus == mm, "O3 lost restore target falls back to the minimap")
    -- 分割畫面：P1 用手把開窗，不搶 P0 的手把
    local e2 = H.load{}
    e2.boot()
    e2.joypads[0] = { id = 0, focus = "p0-ui" }
    e2.joypads[1] = { id = 1, focus = e2.minimap(1) }
    JoypadState.players[1], JoypadState.players[2] = e2.joypads[0], e2.joypads[1]
    local s2 = e2.open(1)
    check(e2.joypads[0].focus == "p0-ui" and e2.joypads[1].focus == s2.win, "O4 split-screen joypad goes to the owner only")
    -- 鍵盤：焦點框在控制項上時方向鍵被吃掉，不漏給遊戲
    local e3 = H.load{}
    e3.boot()
    local s3 = e3.open(0)
    local F = e3.UI.Focus
    F.onKeyPress(s3.win, Keyboard.KEY_TAB)
    F.onKeyPress(s3.win, Keyboard.KEY_DOWN)
    check(F.isKeyConsumed(s3.win, Keyboard.KEY_DOWN), "O5 arrow keys are consumed while a control is focused")
    check(s3.win.wantKeyEvents == true, "O5 window receives key events")
end

io.write(string.format("test_settings_studio: %d assertions, %d failures\n", assertions, failures))
if failures > 0 then os.exit(1) end
io.write("test_settings_studio: PASS (framework gate, four groups, zones/mappack, admin, gates, distance cap, "
    .. "search, toggle invariants, reset, previews, gamepad)\n")
