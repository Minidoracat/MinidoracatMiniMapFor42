-- 地圖顯示設定視窗（_Settings.lua）離線回歸：真的 UI 框架 rev 17 元件＋真的 _Settings／_Markers，
-- 地圖畫法 helper 從各模組原始碼抽出（見 scripts/settings_harness.lua）。缺同層框架 repo＝FAIL（不是 SKIP）。
-- 範圍：框架缺席／過舊只提示不開窗；四組側欄與群組內順序；自訂區域／MOD 地圖有條件出現；管理員組；
-- 沙盒閘停用開關＋提示；顯示距離上限；搜尋布林與跳轉；被世界地圖蓋住置頂；分割畫面換擁有者；
-- 開窗重讀現值；重設；字型模式（大畫面 Medium）與版面放大；小地圖上半往下開、避開快捷列；效果預覽用地圖畫法畫得出來；手把接手與 B 回小地圖；版面在 viewport 內。
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
    -- 真的框架 Toast（rev 17 框架只是少了某個旗標）：整句都要看得到，含最後的「ESC ￫ 選項 ￫ MOD」，
    -- 不能被單行截掉（Toast 預設 maxLines 1）
    local real = H.load{}
    real.boot()
    real.UI.CAPABILITIES.navList = false
    real.Core.toggleSettingsWindow(real.minimap(0))
    local toast = real.UI.Toast.active[#real.UI.Toast.active]
    local shown = toast and table.concat(toast.lines, "") or ""
    checkEq(shown:gsub("%s", ""), T("UI_MinidoracatMiniMap_NeedFramework"):gsub("%s", ""),
        "A6 real Toast shows the whole NeedFramework text over several lines")
    check(toast and toast.holdMs >= 6000, "A6 long notice stays long enough to read")
    check(real.Core.settingsWindow() == nil, "A6 missing capability opens nothing")
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
            "Isometric", "Symbols", "MapTextScale" },
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
    -- chip 小圖染色與地圖同一套：POI 單色＝類別色、彩色＝原色；物種符號風格＝野生物種用野生色、其餘用牲畜色；物品風格＝原色
    local cats = MinidoracatMiniMapPOICategories.CATEGORIES
    s.selectSection("poicat")
    local food = env.byKey("Cat:food")
    check(food.icon and food.icon.poi == "food" and food.iconColor == cats.food.color,
        "H6 mono POI chip icon is tinted with the category colour")
    env.values.PoiColorIcons = true
    s.rebuild()
    food = env.byKey("Cat:food")
    check(food.icon and food.icon.poi == "food" and food.iconColor == nil, "H6 colour POI icons keep their original colour")
    env.values.PoiColorIcons = nil
    s.selectSection("animals")
    local deerChip = env.byKey("AnimalSpeciesFilter:deer")
    local dc = deerChip.iconColor
    check(deerChip.icon and deerChip.icon.sym == "deer.png" and dc and dc.r == 0.47 and dc.g == 0.88 and dc.b == 0.37,
        "H7 symbol-style wild species chip (deer) is tinted with the wild colour (default green)")
    local cc = env.byKey("AnimalSpeciesFilter:cow").iconColor
    check(cc and cc.r == 1 and cc.g == 1 and cc.b == 1,
        "H7 symbol-style farm species chip (cow) is tinted with the livestock colour (default white)")
    env.byKey("AnimalLivestockColor"):setSelected(3)
    env.frame()
    cc = env.byKey("AnimalSpeciesFilter:cow").iconColor
    check(env.values.AnimalLivestockColor == 3 and cc and cc.r == 0.9 and cc.g == 0.62 and cc.b == 0,
        "H7 changing the livestock colour rebuilds the chips with the new tint")
    env.byKey("AnimalWildColor"):setSelected(3)
    env.frame()
    dc = env.byKey("AnimalSpeciesFilter:deer").iconColor
    check(env.values.AnimalWildColor == 3 and dc and dc.r == 0.9 and dc.g == 0.62 and dc.b == 0,
        "H7 changing the wild colour rebuilds the chips with the new tint")
    env.values.AnimalIconStyle = 2
    s.rebuild()
    deerChip = env.byKey("AnimalSpeciesFilter:deer")
    check(deerChip.icon and deerChip.icon.item == "Item_Deer" and deerChip.iconColor == nil,
        "H8 item-style species chip keeps the original colour")
    env.values.AnimalIconStyle, env.values.AnimalLivestockColor, env.values.AnimalWildColor = nil, nil, nil
    local caps = MinidoracatUI.v1.CAPABILITIES
    caps.buttonIconColor = nil
    s.selectSection("poicat")
    food = env.byKey("Cat:food")
    check(food.icon ~= nil and food.iconColor == nil, "H9 rev 17 build without buttonIconColor: chip icon untinted")
    caps.buttonIconColor = true
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
    -- 類別很多：換行後的按鈕不能疊在一起（沒有父元件時原版 setY 會把元件夾在螢幕內，ISUIElement.lua:188-220；
    -- 2026-10-08 實機 100 位作者，第 27 列以後的按鈕全疊在 y=981）
    local cats = {}
    for i = 1, 150 do cats[i] = string.format("category-name-%03d", i) end
    e.zoneCats = cats
    st.selectSection("zones")
    local chips = e.controls(function(el)
        return el._findKey ~= nil and el._findKey:find("ZoneCategoryFilter:", 1, true) == 1 end)
    local stacked
    for i = 2, #chips do
        local a, b = chips[i - 1], chips[i]
        if b.y < a.y or (b.y == a.y and b.x < a.x + a.width) then stacked = b._findKey break end
    end
    checkEq(#chips, 150, "N7 every category gets a chip")
    check(stacked == nil and chips[#chips].y > 1080, "N7 wrapped chips keep going down past the screen height: " .. tostring(stacked))
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

-- ── R 位置：從小地圖開，小地圖在 viewport 下半＝視窗底與小地圖外框底齊平（原版快捷列在它下面）；
--    上半＝視窗頂與小地圖頂齊平往下長；都不壓到看得見的快捷列；世界地圖開照舊 ─────────────
do
    local e = H.load{}
    e.boot()
    local mm = e.minimap(0)
    local st = e.open(0)
    local fullH = st.inspector.height
    checkEq(st.win.y + st.win.height, 1000, "R1 window bottom is level with the minimap bottom")
    checkEq(fullH, (18 + 8) * 24, "R1 enough room above: body keeps its full height (Medium rows)")
    st.win:close()
    mm.absY, mm.height = 200, 800 -- 小地圖比視窗高、中心在下半：照樣底對底
    st = e.open(0)
    checkEq(st.win.y + st.win.height, 1000, "R1 lower-half minimap taller than the window: still bottom-aligned")
    st.win:close()
    mm.absY, mm.height = 500, 150 -- 中心 575 在下半，底 650：上面放不下整個視窗
    st = e.open(0)
    checkEq(st.win.y, 0, "R2 short space: window starts at the viewport top")
    checkEq(st.win.y + st.win.height, 650, "R2 short space: bottom still level with the minimap bottom")
    check(st.inspector.height < fullH and st.inspector.height >= 26 * 8 and st.navScroll.height == st.inspector.height,
        "R2 body shrinks (not below the 8-row minimum)")
    st.selectSection("perf")
    st.inspector:setYScroll(-60)
    check(st.inspector:getScrollHeight() > st.inspector.height and st.inspector:getYScroll() == -60,
        "R2 shrunk inspector still scrolls")
    st.win:close()
    -- 上半：右上角的小地圖（頂 40、高 300）＝頂對頂，往下長到完整高度（以前被擠成底 340、8 列）
    mm.absY, mm.height = 40, 300
    st = e.open(0)
    checkEq(st.win.y, 40, "R3 upper-half minimap: window top level with the minimap top")
    checkEq(st.inspector.height, fullH, "R3 upper-half minimap: window grows downward to its full height")
    st.win:close()
    -- 快捷列：上半時視窗底不壓到看得見的快捷列，放不下才縮
    e.hotbar = { visible = true, y = 600 }
    st = e.open(0)
    check(st.win.y == 40 and st.win.y + st.win.height <= 600 and st.inspector.height < fullH,
        "R3 visible hotbar: the downward window stops above it and shrinks the body")
    st.win:close()
    e.hotbar.visible = false
    st = e.open(0)
    checkEq(st.inspector.height, fullH, "R3 hidden hotbar is ignored")
    st.win:close()
    e.hotbar = { visible = true, y = 200 } -- 空間比最小高度還小：最小高度贏、留在 viewport 內
    st = e.open(0)
    check(st.inspector.height == 26 * 8 and st.win.y == 0 and st.win.y + st.win.height <= 1080,
        "R3 minimum body height wins; the window stays inside the viewport")
    st.win:close()
    -- 下半＋快捷列頂比小地圖底高：視窗底停在快捷列頂
    mm.absY, mm.height = 700, 300
    e.hotbar = { visible = true, y = 980 }
    st = e.open(0)
    checkEq(st.win.y + st.win.height, 980, "R3 lower-half minimap: bottom stays above the hotbar")
    st.win:close()
    e.hotbar = nil
    mm.bottomPanel = { visible = false, height = 30, isVisible = function(self) return self.visible end,
        getHeight = function(self) return self.height end }
    st = e.open(0)
    checkEq(st.win.y + st.win.height, 1031, "R4 collapsed button bar (hover mode): its height is added back")
    mm.bottomPanel.visible = true
    st.win:setY(900)
    st.rebuild()
    checkEq(st.win.y + st.win.height, 1000, "R5 rebuild clamps a dragged window back above the minimap bottom")
    st.win:setY(100)
    st.rebuild()
    checkEq(st.win.y, 100, "R5 rebuild leaves a window that is already above the floor where it is")
    st.win:close()
    mm.absY, mm.height = 40, 300
    st = e.open(0)
    e.hotbar = { visible = true, y = 700 }
    st.rebuild()
    check(st.win.y + st.win.height <= 700, "R5 rebuild clamp uses the same rule (upper half: above the hotbar)")
    st.win:close()
    e.hotbar = nil
    local worldMap = { playerNum = 0, getAbsoluteX = function() return 1200 end, getAbsoluteY = function() return 100 end }
    e.Core.toggleSettingsWindow(worldMap)
    st = e.studio()
    check(st.win.y == 100 and st.inspector.height == fullH, "R6 world map: top aligned with the map, full body")
    st.win:setY(900)
    st.rebuild()
    checkEq(st.win.y + st.win.height, 1080, "R6 world map: rebuild clamps to the viewport bottom only")
end

-- ── F 字型：viewport 夠高（≥900）且 Small 字不大（≤18）＝Medium，內文元件全跟著；版面隨字高放大 ───
do
    local function openWith(h, smallH)
        local e = H.load{}
        e.viewports[0] = { 0, 0, 1920, h }
        e.fontH.Small = smallH
        e.boot()
        return e, e.open(0)
    end
    local e, st = openWith(1080, 14)
    checkEq(st.win.font, UIFont.Medium, "F1 tall viewport + small game font = Medium window")
    checkEq(select(2, openWith(900, 18)).win.font, UIFont.Medium, "F1 thresholds are inclusive (900 px, 18 px)")
    checkEq(select(2, openWith(899, 14)).win.font, UIFont.Small, "F2 viewport under 900 px keeps Small")
    checkEq(select(2, openWith(1080, 19)).win.font, UIFont.Small, "F2 large game font (Small > 18 px) keeps Small")
    -- 內文元件與文字塊：每個分類逐一看
    local function fonts(env, s, want)
        local bad = {}
        if s.nav.font ~= want then bad[#bad + 1] = "nav" end
        if s.search.font ~= want then bad[#bad + 1] = "search" end
        for _, id in ipairs(s.sections) do
            s.selectSection(id)
            for _, el in ipairs(env.studio().controls) do
                local f = el._lines and el._font or el.font
                local header = el._lines and el._font == UIFont.Medium -- 分類標題固定 Medium
                if f ~= nil and f ~= want and not header then bad[#bad + 1] = id .. ":" .. tostring(env.type(el)) end
            end
        end
        return table.concat(bad, ",")
    end
    checkEq(fonts(e, st, UIFont.Medium), "", "F3 large mode: nav, search, every control and text block use Medium")
    local es, ss = openWith(899, 14)
    checkEq(fonts(es, ss, UIFont.Small), "", "F3 small mode: everything stays Small")
    -- 版面：導覽寬＝字高×11 起、車道夾 [字高×21, 字高×30]（此處標籤夠長＝頂到上限）
    e, st = openWith(1080, 14)
    es, ss = openWith(899, 14)
    checkEq(st.inspector.width, 18 * 30 + 28, "F4 Medium lane cap = font height x 30")
    checkEq(ss.inspector.width, 14 * 30 + 28, "F4 Small lane cap = font height x 30")
    -- 下限：字很大（遊戲字級調大＝Small 30px）時標籤撐不到下限，車道＝字高×21
    checkEq(select(2, openWith(1080, 30)).inspector.width, 30 * 21 + 28, "F4 lane floor = font height x 21")
    -- 說明段落用視窗字型斷行：每行以該字型量都不超出文字塊寬
    local over
    st.selectSection("perf")
    for _, el in ipairs(e.studio().controls) do
        for _, line in ipairs(el._lines or {}) do
            if getTextManager():MeasureStringX(el._font, line) > el.width then over = line end
        end
    end
    check(over == nil, "F4 notes wrap with the window font (" .. tostring(over) .. ")")
    check(st.win.width > ss.win.width and st.navScroll.width > ss.navScroll.width, "F4 window and nav grow with the font")
    -- 執行中換了 viewport（換解析度）：下一幀換成新字型的視窗、沿用分類
    st.selectSection("zombie")
    e.viewports[0] = { 0, 0, 1920, 800 }
    e.frame()
    local now = e.studio()
    check(now.win ~= st.win and now.win:isVisible() and now.win.font == UIFont.Small and now.selected == "zombie",
        "F5 viewport change: the window reopens with the new font on the same category")
end

-- ── S 其他玩家標記（多人）：主開關存 ModOptions、作者 chip 走 Core 的切換規則、20 位以上改清單視窗、
--    重設不放回、單機不列、總搜尋不找作者 ──
do
    local sp = H.load{}
    sp.boot()
    check(not table.concat(sp.open(0).sections, ","):find("remote", 1, true), "S1 single player has no remote-symbols category")

    local e = H.load{ mp = true }
    e.boot()
    local hidden, showAllCalls, listSig = {}, 0, "a"
    local authors = { { key = "alice", label = "alice（2）", count = 2 }, { key = "bob", label = "bob（1）", count = 1 } }
    e.Core.remoteSymbolAuthors = function() return authors end
    e.Core.remoteSymbolHidden = function(a) return hidden[a] == true end
    -- 切換規則本身（篩選、圈外作者、封包）在 test_remote_symbols；這裡只看設定視窗怎麼用它
    e.Core.remoteAuthorShown = function(it)
        return not hidden[it.key] and (it.trusted or e.values.RemoteTrustedOnly ~= true)
    end
    e.Core.remoteAuthorSet = function(key, on) hidden[key] = (not on) or nil end
    e.Core.remoteAuthorSetMany = function(list, on)
        for i = 1, #list do hidden[list[i].key] = (not on) or nil end
    end
    e.Core.remoteListSig = function() return listSig end
    e.Core.remoteShowAllAuthors = function() showAllCalls = showAllCalls + 1 end
    local st = e.open(0)
    checkEq(table.concat(st.sections, ","), "base,places,remote,poicat,zombie,animals,vehicles,safehouse,window,perf",
        "S1 multiplayer lists the category right after players and navigation")
    check(navRow(st.nav, "remote").switch ~= nil, "S2 nav shows the master switch")
    st.selectSection("remote")
    local header = e.controls(function(el)
        return el._sec and el._sec.id == "remote" and e.type(el) == "MinidoracatUICheckbox" end)[1]
    check(header ~= nil and header.checked == true, "S2 master defaults to shown")
    checkEq(header and header.tooltip, T("IGUI_MapOption_RemoteSymbols_tooltip"), "S2 master tooltip explains per-author hiding")
    header:forceClick()
    checkEq(e.values.RemoteSymbols, false, "S2 master writes the RemoteSymbols option")
    local alice = e.byKey("RemoteAuthor:alice")
    check(alice ~= nil and alice.title == "alice（2）" and alice:isActive(), "S3 author chip shows the raw label, active = shown")
    alice.onclick(alice.target, alice)
    check(hidden.alice == true and not alice:isActive(), "S3 deselecting an author hides them in the vanilla list")
    local none = byLabel(e, T("UI_MinidoracatMiniMap_SelectNone"))
    none.onclick(none.target, none)
    check(hidden.alice and hidden.bob, "S4 select none hides every author")
    local reset = findControl(e, function(el) return el._sec and el.title == T("UI_MinidoracatMiniMap_StudioResetCategory") end)
    e.byKey("RemoteTrustedOnly"):forceClick()
    reset.onclick(reset.target, reset)
    check(e.values.RemoteSymbols == true and e.values.RemoteTrustedOnly == false and hidden.alice and hidden.bob,
        "S5 reset restores both switches; hidden authors stay hidden")
    e.frame()
    local all = byLabel(e, T("UI_MinidoracatMiniMap_SelectAll"))
    all.onclick(all.target, all)
    check(hidden.alice == nil and hidden.bob == nil, "S4 select all shows every author again")
    -- 只看派系與安全屋：勾了之後，圈外作者的 chip 跟著重畫成關，圈內的照常
    authors[3] = { key = "dave", label = "dave（1）", count = 1, trusted = true }
    st.rebuild()
    local only = e.byKey("RemoteTrustedOnly")
    check(only ~= nil and only.checked == false, "S8 the faction and safehouse filter defaults to off")
    only:forceClick()
    checkEq(e.values.RemoteTrustedOnly, true, "S8 ticking the filter writes RemoteTrustedOnly")
    e.frame()
    alice = e.byKey("RemoteAuthor:alice")
    check(alice ~= nil and not alice:isActive() and e.byKey("RemoteAuthor:dave"):isActive(),
        "S8 filter on: the outsider's chip redraws as off, the member's stays on")
    -- 全部顯示：總開關開、篩選關、清單作者全部放回
    header = e.controls(function(el)
        return el._sec and el._sec.id == "remote" and e.type(el) == "MinidoracatUICheckbox" end)[1]
    header:forceClick()
    check(e.values.RemoteSymbols == false and e.values.RemoteTrustedOnly == true, "S10 setup: master off, filter on")
    local showAll = byLabel(e, T("UI_MinidoracatMiniMap_RemoteShowAll"))
    check(showAll ~= nil and showAll.tooltip == T("UI_MinidoracatMiniMap_RemoteShowAll_tooltip"), "S10 show all sits in the category")
    showAll.onclick(showAll.target, showAll)
    check(e.values.RemoteSymbols == true and e.values.RemoteTrustedOnly == false and showAllCalls == 1,
        "S10 show all turns the master on, the filter off and puts every author back")
    -- 停在這個分類時，作者清單簽章一變就重畫（新分享、派系進出、世界地圖右鍵隱藏），不用切分類
    e.frame()
    for _ = 1, 30 do e.frame() end
    authors[#authors + 1] = { key = "erin", label = "erin（1）", count = 1 }
    for _ = 1, 30 do e.frame() end
    check(e.byKey("RemoteAuthor:erin") == nil, "S11 same signature: no rebuild")
    listSig = "b"
    for _ = 1, 30 do e.frame() end
    check(e.byKey("RemoteAuthor:erin") ~= nil, "S11 a changed signature redraws the chips while the category stays open")
    -- 20 位以內照舊列出；第 21 位起換成摘要＋「管理作者...」（使用者裁定 2026-10-08）
    authors = {}
    for i = 1, 20 do authors[i] = { key = string.format("p%02d", i), label = string.format("p%02d（1）", i), count = 1 } end
    hidden = { p03 = true }
    st.rebuild()
    check(e.byKey("RemoteAuthor:p20") ~= nil and e.byKey("RemoteAuthors") == nil, "S13 twenty authors are still listed as chips")
    authors[21] = { key = "p21", label = "p21（1）", count = 1 }
    st.rebuild()
    check(e.byKey("RemoteAuthor:p01") == nil and byLabel(e, T("UI_MinidoracatMiniMap_SelectAll")) == nil,
        "S13 the 21st author replaces the chips")
    check(textShown(e, getText("UI_MinidoracatMiniMap_RemoteSummary", "21", "1")), "S13 a summary counts authors and hidden ones")
    local manage = e.byKey("RemoteAuthors")
    check(manage ~= nil and manage.title == T("UI_MinidoracatMiniMap_RemoteManage"), "S13 the manage button takes their place")
    manage.onclick(manage.target, manage)
    local lw = e.Core.remoteListWindow()
    check(lw ~= nil and lw.win:isVisible() and #lw.items == 21, "S13 the manage button opens the list window with every author")
    lw.win:close()
    authors = {}
    st.rebuild()
    check(textShown(e, T("UI_MinidoracatMiniMap_RemoteNoAuthors")), "S6 an empty list says nobody shares with you")
    -- 設定視窗的總搜尋不找作者：找人到清單視窗裡搜（使用者裁定 2026-10-08）
    authors = { { key = "carol", label = "carol（1）", count = 1 } }
    st.win._sig = nil -- 讓索引用現在的作者重建（分類有變時才重建）
    st.rebuild()
    st.search._entry:setText("carol")
    st.search:prerender()
    e.frame()
    check(e.controls(function(el) return el._hit ~= nil end)[1] == nil
        and textShown(e, T("UI_MinidoracatMiniMap_StudioNoResults")), "S7 the settings search does not list authors")
    st.search._entry:setText("")
    st.search:prerender()
    e.frame()
end

-- ── L 作者清單視窗：搜尋（任一段、不分大小寫、中文）、只看已隱藏、整列切換、底部按鈕只作用在目前清單、自動重整 ──
do
    local e = H.load{ mp = true }
    e.boot()
    local hidden, calls, listSig = { Gunner27 = true }, {}, "a"
    local authors = {}
    for _, name in ipairs({ "BigGun99", "G_u_n", "Gunner07", "Gunner27", "gunslinger", "小明不在家", "我是小明" }) do
        authors[#authors + 1] = { key = name, label = name, count = #authors + 1 }
    end
    for i = 1, 20 do authors[#authors + 1] = { key = string.format("p%02d", i), label = "p", count = 1 } end
    e.Core.remoteSymbolAuthors = function() return authors end
    e.Core.remoteSymbolHidden = function(a) return hidden[a] == true end
    e.Core.remoteAuthorShown = function(it) return not hidden[it.key] end
    e.Core.remoteAuthorSet = function(key, on)
        calls[#calls + 1] = key .. (on and "+" or "-")
        hidden[key] = (not on) or nil
    end
    e.Core.remoteAuthorSetMany = function(list, on)
        local keys = {}
        for i = 1, #list do
            keys[i] = list[i].key
            hidden[list[i].key] = (not on) or nil
        end
        calls[#calls + 1] = table.concat(keys, ",") .. (on and "+" or "-")
    end
    e.Core.remoteListSig = function() return listSig end
    local st = e.open(0)
    st.selectSection("remote")
    local manage = e.byKey("RemoteAuthors")
    manage.onclick(manage.target, manage)
    local lw = e.Core.remoteListWindow()
    local function keys()
        local out = {}
        for i, it in ipairs(lw.list:getItems()) do out[i] = it.key end
        return table.concat(out, ",")
    end
    local function search(text)
        lw.search._entry:setText(text)
        lw.search:prerender()
    end
    checkEq(lw.meta, getText("UI_MinidoracatMiniMap_RemoteListCount", "27", "27", "1"), "L1 the count line shows totals")
    local lx, sx = lw.win:getX(), st.win:getAbsoluteX()
    check(lx >= sx + st.win.width or lx + lw.win.width <= sx, "L1 the window opens beside the settings window, not over it")
    search("  GUN ")
    checkEq(keys(), "BigGun99,Gunner07,Gunner27,gunslinger", "L2 search matches any part of the name, ignoring case and spaces")
    checkEq(e.Core.remoteListWindow().meta, getText("UI_MinidoracatMiniMap_RemoteListCount", "27", "4", "1"),
        "L2 the count line follows the search")
    checkEq(lw.showBtn.title, getText("UI_MinidoracatMiniMap_RemoteShowThese", "4"), "L2 the bottom buttons name the count")
    search("小明")
    checkEq(keys(), "小明不在家,我是小明", "L3 Chinese names match too")
    search("gun")
    lw.only:forceClick()
    checkEq(keys(), "Gunner27", "L4 hidden only keeps the hidden authors among the matches")
    lw.only:forceClick()
    -- 整列點一下＝切換（滑鼠、Enter、手把 A 都走 onSelect）
    local items = lw.list:getItems()
    lw.list.onSelect(lw.list, items[2], 2)
    checkEq(calls[#calls], "Gunner07-", "L5 clicking a shown row hides that author")
    items = lw.list:getItems()
    lw.list.onSelect(lw.list, items[3], 3)
    checkEq(calls[#calls], "Gunner27+", "L5 clicking a hidden row shows that author")
    -- 底部按鈕只作用在目前清單上的作者
    lw.hideBtn.onclick(lw.hideBtn.target, lw.hideBtn)
    checkEq(calls[#calls], "BigGun99,Gunner07,Gunner27,gunslinger-", "L6 hide these only touches the listed authors")
    check(hidden.p01 == nil and hidden["我是小明"] == nil, "L6 authors outside the search stay as they were")
    lw.showBtn.onclick(lw.showBtn.target, lw.showBtn)
    checkEq(calls[#calls], "BigGun99,Gunner07,Gunner27,gunslinger+", "L6 show these puts the same authors back")
    search("zzz")
    check(#lw.list:getItems() == 0 and not lw.showBtn:isEnabled() and not lw.hideBtn:isEnabled(),
        "L7 no match: empty list and both buttons disabled")
    checkEq(e.Core.remoteListWindow().meta, T("UI_MinidoracatMiniMap_RemoteListEmpty"), "L7 the count line says nothing matches")
    -- 開著時簽章一變（新分享、派系進出、別處改了隱藏）就重整
    search("")
    authors[#authors + 1] = { key = "zed", label = "zed", count = 1 }
    for _ = 1, 30 do e.frame() end
    check(not keys():find("zed", 1, true), "L8 same signature: no refresh")
    listSig = "b"
    for _ = 1, 30 do e.frame() end
    check(keys():find("zed", 1, true) ~= nil, "L8 a changed signature refreshes the open list")
end

io.write(string.format("test_settings_studio: %d assertions, %d failures\n", assertions, failures))
if failures > 0 then os.exit(1) end
io.write("test_settings_studio: PASS (framework gate, four groups, zones/mappack, admin, gates, distance cap, "
    .. "search, toggle invariants, reset, previews, gamepad)\n")
