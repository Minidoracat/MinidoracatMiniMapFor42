-- MiniMap addon client-settings API（registerSettingsSection v1–v5）與設定視窗擴充分類的離線回歸：
-- 前半抽 registry 區段驗正規化；後半以真框架＋真 _Settings 驗分組排序、圖層區塊、控制項與重設。
local sourcePath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Settings.lua"

local file = assert(io.open(sourcePath, "rb"))
local source = file:read("*a"):gsub("\r\n", "\n")
file:close()
local compile = loadstring or load

local assertions, failures = 0, 0
local function check(value, label)
    assertions = assertions + 1
    if not value then failures = failures + 1; io.write("FAIL " .. label .. "\n") end
end
local function checkEq(actual, expected, label)
    check(actual == expected, label .. " (expected=" .. tostring(expected)
        .. ", actual=" .. tostring(actual) .. ")")
end

local registryBody = assert(source:match(
    "%-%- test:addon%-settings%-registry:start\n(.-)\n%-%- test:addon%-settings%-registry:end"),
    "missing addon settings registry test block")
local registryChunk, registryErr = compile([[
local messages = {}
local function print(message) messages[#messages + 1] = message end
local addonSettingsById = {}
local addonSectionOrder = {}
local settingsUI = { visible = false, _sig = "built" }
function settingsUI:isVisible() return self.visible end
local dirtyCalls = 0
local function studioMarkDirty() dirtyCalls = dirtyCalls + 1 end
MinidoracatMiniMapAPI = {}
local layerCalls = {}
local Core = { registerMarkerLayers = function(owner, layers)
    layerCalls[#layerCalls + 1] = { owner = owner, layers = layers }
end }
]] .. registryBody .. "\n" .. [=[
return {
    api = MinidoracatMiniMapAPI,
    registry = addonSettingsById,
    order = addonSectionOrder,
    ui = settingsUI,
    dirty = function() return dirtyCalls end,
    messages = messages,
    layerCalls = layerCalls,
}
]=])
assert(registryChunk, registryErr)
local registry = registryChunk()
local api = registry.api

checkEq(api.settingsApiVersion, 5, "settings API version")
check(not api.registerSettingsSection(nil, {}), "nil owner rejected")
check(not api.registerSettingsSection("A", {}), "missing label rejected")
check(not api.registerSettingsSection("A", { label = "UI_A", ticks = {
    { label = "UI_T", get = function() return true end },
} }), "tick missing setter rejected")
check(not api.registerSettingsSection("A", { label = "UI_A", combos = {
    { label = "UI_C", get = function() return 1 end, set = function() end,
        items = { "UI_1", 2 } },
} }), "non-string combo item rejected")
check(not api.registerSettingsSection("A", { label = "UI_A", combos = { 1 } }),
    "non-table combo entry rejected without throwing")
check(not api.registerSettingsSection("A", { label = "UI_A", combos = {
    { label = "UI_C", get = function() return 1 end, set = function() end,
        default = false, items = { "UI_1" } },
} }), "non-number combo default rejected")
checkEq(#registry.order, 0, "invalid registrations do not append sections")

local visible = true
local width = 2
local specA = {
    label = "UI_A", lane = 2, summary = function() return "1/1" end,
    ticks = { { label = "UI_Show", tooltip = "UI_Show_tip",
        get = function() return visible end,
        set = function(v) visible = v end } },
    combos = { { label = "UI_Width", items = { "UI_Thin", "UI_Normal", "UI_Thick" },
        default = 2, get = function() return width end,
        set = function(v) width = v end } },
}
check(api.registerSettingsSection("OwnerA", specA), "valid owner A registers")
checkEq(registry.order[1], registry.registry.OwnerA, "valid section enters registration order")
checkEq(registry.registry.OwnerA.id, "addon_OwnerA", "section id derived from owner")
checkEq(registry.ui._sig, nil, "registration invalidates nav/search signature")
checkEq(registry.registry.OwnerA.addon.lane, nil, "lane ignored and not stored")
checkEq(registry.registry.OwnerA.addon.summary, nil, "summary ignored and not stored")
check(registry.registry.OwnerA.addon ~= specA, "external spec copied")
specA.label = "MUTATED"
specA.combos[1].items[1] = "MUTATED_ITEM"
checkEq(registry.registry.OwnerA.label, "UI_A", "later label mutation isolated")
checkEq(registry.registry.OwnerA.addon.combos[1].items[1], "UI_Thin",
    "later items mutation isolated")
checkEq(#registry.registry.OwnerA.addon.actions, 0, "v1 spec stores empty actions")

check(api.registerSettingsSection("OwnerB", {
    label = "UI_A", ticks = { { label = "UI_B", get = function() return false end,
        set = function() end } },
}), "different owner with same label registers independently")
checkEq(#registry.order, 2, "different owner gets its own section")
checkEq(registry.order[2], registry.registry.OwnerB, "second addon follows in registration order")

local oldSection = registry.registry.OwnerA
check(api.registerSettingsSection("OwnerA", {
    label = "UI_A2", lane = "full", ticks = {
        { label = "UI_Show2", get = function() return true end, set = function() end },
    },
}), "same owner re-registers")
checkEq(#registry.order, 2, "same owner replacement is idempotent")
checkEq(registry.registry.OwnerA, oldSection, "same section identity retained")
checkEq(oldSection.label, "UI_A2", "same owner updates label")
checkEq(oldSection.addon.lane, nil, "re-registration still ignores lane")
registry.ui.visible = true
local beforeDirty = registry.dirty()
check(api.registerSettingsSection("OwnerA", {
    label = "UI_A3", ticks = {
        { label = "UI_Show3", get = function() return true end, set = function() end },
    },
}), "visible-window replacement succeeds")
checkEq(registry.dirty(), beforeDirty + 1, "visible window rebuilds on registration")
check(#registry.messages >= 4, "invalid registrations leave diagnostics")

check(not api.registerSettingsSection("A", { label = "UI_A", actions = "no" }),
    "non-table actions rejected")
check(not api.registerSettingsSection("A", { label = "UI_A", actions = { 1 } }),
    "non-table action entry rejected without throwing")
check(not api.registerSettingsSection("A", { label = "UI_A", actions = {
    { label = "UI_Copy", run = function() end },
} }), "action missing tooltip rejected")
check(not api.registerSettingsSection("A", { label = "UI_A", actions = {
    { label = "UI_Copy", tooltip = "", run = function() end },
} }), "empty action tooltip rejected")
check(not api.registerSettingsSection("A", { label = "UI_A", actions = {
    { label = "UI_Copy", tooltip = "UI_Copy_tip" },
} }), "action missing run rejected")
check(not api.registerSettingsSection("A", { label = "UI_A", actions = {
    { tooltip = "UI_Copy_tip", run = function() end },
} }), "action missing label rejected")
check(not api.registerSettingsSection("A", { label = "UI_A", actions = {
    { label = "UI_Copy", tooltip = "UI_Copy_tip", run = function() end,
        enabled = true },
} }), "non-function action enabled rejected")
local tooMany = {}
for i = 1, 17 do
    tooMany[i] = { label = "UI_A", tooltip = "UI_T", run = function() end }
end
check(not api.registerSettingsSection("A", { label = "UI_A", actions = tooMany }),
    "17 actions rejected")
checkEq(#registry.order, 2, "invalid actions do not append sections")

local specC = {
    label = "UI_C",
    actions = {
        { label = "UI_Copy", tooltip = "UI_Copy_tip",
            run = function() end, enabled = function() return true end },
    },
}
registry.ui._sig = "built"
check(api.registerSettingsSection("OwnerC", specC), "valid action registers")
checkEq(registry.ui._sig, nil, "action registration rebuilds search index")
local act = registry.registry.OwnerC.addon.actions[1]
checkEq(act.label, "UI_Copy", "action label stored")
checkEq(act.tooltip, "UI_Copy_tip", "action tooltip stored")
check(act.run == specC.actions[1].run, "action run kept")
check(act.enabled == specC.actions[1].enabled, "action enabled kept")
check(registry.registry.OwnerC.addon.actions ~= specC.actions, "actions array copied")
specC.actions[1].label = "MUTATED"
checkEq(act.label, "UI_Copy", "later action label mutation isolated")
check(api.registerSettingsSection("OwnerC", {
    label = "UI_C2",
    actions = { { label = "UI_Copy2", tooltip = "UI_Copy2_tip", run = function() end } },
}), "action hot reload succeeds")
checkEq(registry.registry.OwnerC.addon.actions[1].label, "UI_Copy2",
    "hot reload updates action")
checkEq(#registry.registry.OwnerC.addon.actions, 1, "hot reload action count")
checkEq(#registry.registry.OwnerC.addon.ticks, 0, "hot reload clears omitted ticks")

-- v3：visible(pn) 選用；非函式拒收，函式原樣保存；註冊順序表每 owner 只進一次
check(not api.registerSettingsSection("OwnerD", { label = "UI_D", visible = true }),
    "non-function visible rejected")
local visibleFn = function() return false end
check(api.registerSettingsSection("OwnerD", { label = "UI_D", visible = visibleFn })
    and registry.registry.OwnerD.addon.visible == visibleFn, "visible function stored")
checkEq(#registry.order, 4, "each owner enters registration order once")
api.registerSettingsSection("OwnerD", { label = "UI_D2" })
check(#registry.order == 4 and registry.registry.OwnerD.addon.visible == nil,
    "re-registration keeps order and drops omitted visible")

-- v4：sliders。壞值整個 spec 拒收（fail closed）；合法值複製、default 對齊 step、fmt 預設依整數性
local function sliderSpec(over)
    local e = { label = "UI_Vol", min = 0, max = 100, step = 5,
        get = function() return 50 end, set = function() end }
    for k, v in pairs(over) do e[k] = v end
    return { label = "UI_S", sliders = { e } }
end
local nan, inf = 0 / 0, math.huge
local badSliders = {
    { { min = 10, max = 10 }, "min == max" },
    { { min = 20, max = 10 }, "min > max" },
    { { step = 0 }, "zero step" },
    { { step = -5 }, "negative step" },
    { { step = nan }, "NaN step" },
    { { step = 200 }, "step wider than range" },
    { { min = nan }, "NaN min" },
    { { min = -inf }, "infinite min" },
    { { max = inf }, "infinite max" },
    { { min = "0" }, "string min" },
    { { default = 101 }, "default above max" },
    { { default = -1 }, "default below min" },
    { { default = true }, "non-number default" },
    { { fmt = 5 }, "non-string fmt" },
    { { fmt = "%y" }, "fmt that throws" },
    { { fmt = "%30d" }, "fmt wider than value label" },
    { { set = "x" }, "non-function set" },
    { { get = false }, "non-function get" },
    { { label = "" }, "empty label" },
    { { tooltip = 3 }, "non-string tooltip" },
}
for i = 1, #badSliders do
    check(not api.registerSettingsSection("OwnerS", sliderSpec(badSliders[i][1])),
        "slider " .. badSliders[i][2] .. " rejected")
end
check(not api.registerSettingsSection("OwnerS", { label = "UI_S", sliders = "x" }),
    "non-table sliders rejected")
check(not api.registerSettingsSection("OwnerS", { label = "UI_S", sliders = { 1 } }),
    "non-table slider entry rejected without throwing")
local tooManySliders = {}
for i = 1, 33 do tooManySliders[i] = sliderSpec({}).sliders[1] end
check(not api.registerSettingsSection("OwnerS", { label = "UI_S", sliders = tooManySliders }),
    "33 sliders rejected")
checkEq(registry.registry.OwnerS, nil, "rejected slider specs never register")
local sliderSrc = sliderSpec({ default = 47, tooltip = "UI_Vol_tip", fmt = "%d%%" })
check(api.registerSettingsSection("OwnerS", sliderSrc), "valid slider registers")
local sl = registry.registry.OwnerS.addon.sliders[1]
check(sl ~= sliderSrc.sliders[1] and sl.min == 0 and sl.max == 100 and sl.step == 5
    and sl.fmt == "%d%%" and sl.tooltip == "UI_Vol_tip" and sl.get == sliderSrc.sliders[1].get,
    "slider copied with range, fmt, tooltip and callbacks")
checkEq(sl.default, 45, "slider default snapped to step")
sliderSrc.sliders[1].max = 5
checkEq(sl.max, 100, "later slider mutation isolated")
api.registerSettingsSection("OwnerS", sliderSpec({}))
checkEq(registry.registry.OwnerS.addon.sliders[1].default, 0, "missing default falls back to min")
checkEq(registry.registry.OwnerS.addon.sliders[1].fmt, "%d", "integral range defaults to %d")
api.registerSettingsSection("OwnerS", sliderSpec({ min = 0, max = 1, step = 0.1, default = 1 }))
check(registry.registry.OwnerS.addon.sliders[1].fmt == "%.2f"
    and registry.registry.OwnerS.addon.sliders[1].default == 1,
    "fractional step defaults to %.2f and keeps max default")
checkEq(#registry.registry.OwnerC.addon.sliders, 0, "spec without sliders stores empty sliders")

-- v5：icon／group／order／layers；壞值整個 spec 拒收，缺值有預設；tick default 缺＝nil
local v4 = registry.registry.OwnerA
check(v4.icon == "plug" and v4.group == "addon" and v4.order == 100 and v4.seq == 1
    and v4.owner == "OwnerA" and #v4.addon.layers == 0,
    "v4 spec gets plug icon, addon group, order 100, registration seq")
checkEq(registry.registry.OwnerB.seq, 2, "registration seq follows first registration")
local badV5 = {
    { { icon = 3 }, "non-string icon" },
    { { group = true }, "non-string group" },
    { { order = "1" }, "non-number order" },
    { { order = 0 / 0 }, "NaN order" },
    { { order = math.huge }, "infinite order" },
    { { layers = "x" }, "non-table layers" },
    { { layers = { 1 } }, "non-table layer" },
    { { layers = { { id = "a b", label = "L" } } }, "id outside [%w_-]" },
    { { layers = { { id = "a", label = "L" }, { id = "a", label = "M" } } }, "duplicate layer id" },
    { { layers = { { id = "a" } } }, "layer without label" },
    { { layers = { { id = "a", label = "L", size = 7 } } }, "size below 8" },
    { { layers = { { id = "a", label = "L", size = 49 } } }, "size above 48" },
    { { layers = { { id = "a", label = "L", size = 16.5 } } }, "fractional size" },
    { { layers = { { id = "a", label = "L", show = { mini = 1 } } } }, "non-boolean show flag" },
    { { layers = { { id = "a", label = "L", names = true } } }, "non-table names" },
    { { layers = { { id = "a", label = "L", namesMiniLabel = "" } } }, "empty names label" },
    { { layers = { { id = "a", label = "L", sample = "car" } } }, "non-table sample" },
}
for i = 1, #badV5 do
    local spec5 = badV5[i][1]
    spec5.label = "UI_V5"
    check(not api.registerSettingsSection("OwnerV", spec5), "v5 " .. badV5[i][2] .. " rejected")
end
local nineLayers = {}
for i = 1, 9 do nineLayers[i] = { id = "l" .. i, label = "L" } end
check(not api.registerSettingsSection("OwnerV", { label = "UI_V5", layers = nineLayers }), "9 layers rejected")
check(not api.registerSettingsSection("Own;er", { label = "UI_V5", layers = { { id = "a", label = "L" } } }),
    "owner with a MarkerLayers separator cannot declare layers")
checkEq(registry.registry.OwnerV, nil, "rejected v5 specs never register")
local sample = { texture = "car" }
local v5src = { label = "UI_V5", icon = "coins", group = "admin", order = 30,
    ticks = { { label = "UI_T", get = function() return true end, set = function() end } },
    layers = { { id = "terminals", label = "UI_Term", sample = sample },
        { id = "bound", label = "UI_Bound", size = 20, show = { world = false },
            names = { mini = false }, namesMiniLabel = "UI_NM" } } }
check(api.registerSettingsSection("OwnerV", v5src), "valid v5 spec registers")
local v5 = registry.registry.OwnerV
check(v5.icon == "coins" and v5.group == "admin" and v5.order == 30 and v5.addon.icon == "coins",
    "icon, group and order kept on the section record")
checkEq(v5.addon.ticks[1].default, nil, "tick without default stays nil")
local la, lb = v5.addon.layers[1], v5.addon.layers[2]
check(la.size == 16 and la.show.mini and la.show.world and la.names == nil and la.sample == sample,
    "layer defaults: size 16, shown on both maps, no names, sample kept")
check(lb.size == 20 and lb.show.mini and not lb.show.world and lb.names.mini == false
    and lb.names.world == true and lb.namesMiniLabel == "UI_NM" and lb.show ~= v5src.layers[2].show,
    "layer flags copied with missing flags defaulting to true")
local lc = registry.layerCalls[#registry.layerCalls]
check(lc.owner == "OwnerV" and lc.layers == v5.addon.layers, "layers handed to the marker layer registry")
api.registerSettingsSection("OwnerV", { label = "UI_V5", group = "other" })
check(v5.group == "addon" and v5.icon == "plug" and #registry.layerCalls[#registry.layerCalls].layers == 0,
    "unknown group falls back to addon; re-registration clears icon and layers")

-- ════════════════════════════════════════════════════════════════════════════
-- 視窗端：真的 UI 框架＋真的 _Settings／_Markers（scripts/settings_harness.lua）
-- ════════════════════════════════════════════════════════════════════════════
local H = dofile("scripts/settings_harness.lua")
if not H.frameworkPresent() then
    io.write("FAIL test_addon_settings: UI framework not found (clone MinidoracatUIFor42 beside this repo or set MUI_LUA)\n")
    os.exit(1)
end
local env = H.load{}
env.boot()
local API, Core = env.API, env.Core
local T = function(key) return getText(key) end
local function noop() end

-- ── 分組與排序：擴充組依 (order, seq)、管理員組＝管理員檢視在前、visible(pn) ─────────
local calls = {}
local vmShowMini
local autoTick, setBool = nil, {}
check(API.registerSettingsSection("Plain", { label = "UI_Plain" }), "W1 v1-style section registers")
check(API.registerSettingsSection("AutoDrive", { label = "UI_AD", icon = "gauge", order = 15,
    ticks = {
        { label = "UI_ADDefaultTrue", default = true, get = function() return setBool.a ~= false end,
            set = function(v) setBool.a = v end, tooltip = "UI_ADTip" },
        { label = "UI_ADNoDefault", get = function() return setBool.b == true end,
            set = function(v) setBool.b = v end },
    },
    combos = { { label = "UI_ADCombo", items = { "UI_I1", "UI_I2", "UI_I3" }, default = 2,
        get = function() return setBool.combo or 3 end, set = function(v) setBool.combo = v end, tooltip = "UI_ADComboTip" } },
    sliders = { { label = "UI_ADVol", min = 3, max = 98, step = 5, default = 48, fmt = "%d%%",
        get = function() return setBool.vol or 48 end, set = function(v) setBool.vol = v end } },
    actions = {
        { label = "UI_ADCopy", tooltip = "UI_ADCopyTip", run = function(pn) calls.run = pn end },
        { label = "UI_ADOff", tooltip = "UI_ADOffTip", run = function() calls.off = true end,
            enabled = function(pn) calls.enabledPn = pn; return false end },
        { label = "UI_ADBoom", tooltip = "UI_ADBoomTip", run = function() error("boom") end },
    },
}), "W1 AutoDrive-like section registers")
check(API.registerSettingsSection("Watch", { label = "UI_Watch", icon = "watch", order = 12 }), "W1 watch registers")
check(API.registerSettingsSection("VM", { label = "UI_VM", icon = "carSedan", order = 40,
    layers = { { id = "bound", label = "UI_VMBound", size = 16, names = { mini = true, world = true },
        namesMiniLabel = "UI_VMNamesMini",
        sample = { texture = { tex = "car" }, r = 1, g = 0.8, b = 0.2, label = "MyCar",
            badge = { texture = { tex = "badge" } }, ring = { r = 1, g = 1, b = 1 }, state = "live" } } },
    actions = { { label = "UI_VMOpen", tooltip = "UI_VMOpenTip", run = function(pn) calls.fleet = pn end } },
}), "W1 VM-like section with a layer registers")
check(API.registerSettingsSection("Econ", { label = "UI_Econ", icon = "coins", order = 30,
    layers = { { id = "terminals", label = "UI_Term", size = 16 } } }), "W1 economy registers")
check(API.registerSettingsSection("AD2", { label = "UI_AD2", order = 15 }), "W1 same order, later seq")
check(API.registerSettingsSection("WatchAdmin", { label = "UI_WatchAdmin", icon = "settings", group = "admin", order = 12,
    actions = { { label = "UI_WatchAdminOpen", tooltip = "UI_WatchAdminOpen_tip", run = function() end } },
    visible = function(pn) calls.visiblePn = pn; return pn == 0 end }), "W1 admin-group section registers")
check(API.registerSettingsSection("Broken", { label = "UI_Broken", order = 50,
    visible = function() error("visible boom") end }), "W1 throwing visible registers")
check(API.registerSettingsSection("Hidden", { label = "UI_Hidden", order = 5,
    visible = function() return false end }), "W1 hidden section registers")

env.policy.can, env.policy.allowTactical = true, true
local s = env.open(0)
checkEq(table.concat(s.sections, ","),
    "base,places,poicat,zombie,animals,vehicles,safehouse,window,perf,addon_Watch,addon_AutoDrive,addon_AD2,"
    .. "addon_Econ,addon_VM,addon_Broken,addon_Plain,admin,addon_WatchAdmin",
    "W2 add-ons by (order, seq); hidden dropped; admin view first in the admin group")
checkEq(calls.visiblePn, 0, "W2 visible(pn) receives the owner slot")
local logged = 0
for _, m in ipairs(env.printed) do if m:find("visible() error", 1, true) then logged = logged + 1 end end
checkEq(logged, 1, "W2 throwing visible keeps the section and logs once")
s.rebuild()
logged = 0
for _, m in ipairs(env.printed) do if m:find("visible() error", 1, true) then logged = logged + 1 end end
checkEq(logged, 1, "W2 visible error logged only once")
do
    local icons, headers = {}, {}
    s.nav:prerender()
    for _, row in ipairs(s.nav._rows) do
        if row.header then headers[#headers + 1] = row.title
        elseif row.id:find("^addon_") then icons[#icons + 1] = row.id .. "=" .. row.icon end
    end
    checkEq(table.concat(headers, "|"), T("UI_MinidoracatMiniMap_GroupLayers") .. "|" .. T("UI_MinidoracatMiniMap_GroupWindow")
        .. "|" .. T("UI_MinidoracatMiniMap_GroupAddons") .. "|" .. T("UI_MinidoracatMiniMap_GroupAdmin"),
        "W3 four group headers")
    checkEq(table.concat(icons, ","), "addon_Watch=watch,addon_AutoDrive=gauge,addon_AD2=plug,addon_Econ=coins,"
        .. "addon_VM=carSedan,addon_Broken=plug,addon_Plain=plug,addon_WatchAdmin=settings", "W3 nav uses sec.icon")
end
-- 另一位分割畫面玩家：visible(pn) 依擁有者
env.Core.toggleSettingsWindow(env.minimap(1))
s = env.studio()
check(not table.concat(s.sections, ","):find("addon_WatchAdmin", 1, true), "W4 visible(pn)=false for P1 hides the section")
env.Core.toggleSettingsWindow(env.minimap(1))
s = env.open(0)

-- ── v5 圖層區塊：開關／世界地圖／大小／名稱都寫 Core.setMarkerLayer（MarkerLayers）──────
s.selectSection("addon_VM")
do
    local function box(label)
        return env.controls(function(el) return el.label == label and el._field ~= nil end)[1]
    end
    local sw = env.byKey("layer:bound")
    check(sw and sw._field == "showMini" and sw.checked == true and sw.label == "", "L1 layer header switch = show.mini")
    check(env.controls(function(el) return el._lines and el._lines[1] == "UI_VMBound" end)[1] ~= nil,
        "L1 layer header shows the layer label")
    sw:forceClick()
    checkEq(env.values.MarkerLayers, "VM/bound=0,1,16,1,1", "L2 header switch writes MarkerLayers via setMarkerLayer")
    check(Core.markerLayer("VM", "bound").show.mini == false, "L2 marker layer prefs follow")
    local world = box(T("UI_MinidoracatMiniMap_WorldAlso"))
    check(world and world.checked == true, "L3 world-map checkbox bound to show.world")
    world:forceClick()
    checkEq(env.values.MarkerLayers, "VM/bound=0,0,16,1,1", "L3 world checkbox writes show.world")
    local namesMini = box("UI_VMNamesMini")
    local namesWorld = box(T("UI_MinidoracatMiniMap_LayerNamesWorld"))
    check(namesMini and namesWorld, "L4 custom names-mini label and default names-world label")
    namesWorld:forceClick()
    checkEq(env.values.MarkerLayers, "VM/bound=0,0,16,1,0", "L4 names checkbox writes namesWorld")
    local size = env.controls(function(el) return el._layerId == "bound" and env.type(el) == "MinidoracatUISliderRow" end)[1]
    check(size and size.min == 8 and size.max == 48 and size:getValue() == 16, "L5 size slider 8-48 at the layer size")
    env.mouseDown = true
    size:setValue(30)
    env.frame()
    checkEq(env.values.MarkerLayers, "VM/bound=0,0,16,1,0", "L5 size not written while dragging")
    -- 預覽讀滑條現值（拖曳中即時），表面關閉＝不畫
    local pv = env.controls(function(el) return env.type(el) == "MinidoracatUIPreview" end)[1]
    check(pv ~= nil, "L6 layer block has a preview")
    sw:forceClick() -- 小地圖再開
    pv.draws = {}
    pv:prerender()
    local texSizes, labels = {}, 0
    for _, d in ipairs(pv.draws) do
        if d.kind == "tex" and d[1] and d[1].tex == "car" then texSizes[#texSizes + 1] = d[4] end
        if d.kind == "text" and d[1] == "MyCar" then labels = labels + 1 end
    end
    check(not pv._failed and #texSizes == 1, "L6 preview draws the sample via drawMarkerAt (mini only, world off)")
    checkEq(texSizes[1], math.floor(12 * 30 / 16 + 0.5), "L6 preview follows the live size slider")
    checkEq(labels, 2, "L6 mini names on: label (shadow + text)")
    env.mouseDown = false
    env.frame()
    checkEq(env.values.MarkerLayers, "VM/bound=1,0,30,1,0", "L7 size written on release")
    local fleet = env.controls(function(el) return el.title == "UI_VMOpen" end)[1]
    fleet.onclick(fleet.target, fleet)
    checkEq(calls.fleet, 0, "L8 action button runs with the owner pn")
    local reset = env.controls(function(el) return el._sec and el.title == T("UI_MinidoracatMiniMap_StudioResetCategory") end)[1]
    reset.onclick(reset.target, reset)
    checkEq(env.values.MarkerLayers, "", "L9 reset restores layer defaults (resetMarkerLayers)")
    env.frame()
    check(env.byKey("layer:bound").checked == true, "L9 inspector rebuilt with default layer values")
    s.selectSection("addon_Econ")
    check(env.byKey("layer:terminals") ~= nil, "L10 layer without names: block has no name toggles")
    check(env.controls(function(el) return el._field == "namesMini" end)[1] == nil, "L10 no names checkboxes")
    check(env.controls(function(el) return env.type(el) == "MinidoracatUIPreview" end)[1] == nil, "L10 no sample = no preview")
end

-- ── ticks／combos／sliders／actions ───────────────────────────────────────────
s.selectSection("addon_AutoDrive")
do
    local t1 = env.controls(function(el) return el.label == "UI_ADDefaultTrue" end)[1]
    check(t1 and env.type(t1) == "MinidoracatUICheckbox" and t1.checked and t1.tooltip == "UI_ADTip",
        "A1 tick = Checkbox from get() with tooltip")
    t1:forceClick()
    checkEq(setBool.a, false, "A1 tick writes through set")
    local nd = env.controls(function(el) return el.label == "UI_ADNoDefault" end)[1]
    nd:forceClick()
    checkEq(setBool.b, true, "A2 no-default tick writes")
    local dd = env.controls(function(el) return env.type(el) == "MinidoracatUIDropdown" end)[1]
    check(dd and dd:getSelected() == 3 and dd.tooltip == "UI_ADComboTip", "A3 combo = Dropdown at get() with tooltip")
    dd:setSelected(1)
    checkEq(setBool.combo, 1, "A3 dropdown writes the index")
    local row = env.controls(function(el) return el._entry and el._entry.label == "UI_ADVol" end)[1]
    check(row and env.type(row) == "MinidoracatUISliderRow" and row:getValue() == 48, "A4 slider = SliderRow at get()")
    row:setValue(50)
    check(row:getValue() == 48 and setBool.vol == nil, "A4 min-based quantisation: 50 snaps to the 3+5k grid (48), no write")
    row:onFocusKey(Keyboard.KEY_RIGHT)
    checkEq(setBool.vol, 53, "A4 keyboard step moves one grid step from min")
    row:setValue(1000)
    checkEq(setBool.vol, 98, "A4 clamped to max")
    row:prerender()
    check(row._text == "98%", "A4 value text uses the spec fmt (" .. tostring(row._text) .. ")")
    local off = env.controls(function(el) return el.title == "UI_ADOff" end)[1]
    check(off and off:isEnabled() == false and calls.enabledPn == 0, "A5 enabled(pn)=false disables the action")
    local copy = env.controls(function(el) return el.title == "UI_ADCopy" end)[1]
    copy.onclick(copy.target, copy)
    checkEq(calls.run, 0, "A5 run receives pn")
    local boom = env.controls(function(el) return el.title == "UI_ADBoom" end)[1]
    local n = #env.printed
    local ok = pcall(boom.onclick, boom.target, boom)
    check(ok and #env.printed == n + 1 and env.printed[#env.printed]:find("addon action failed", 1, true),
        "A6 throwing action is isolated and logged")
    -- 重設：有 default 的寫回、沒宣告 default 的不動、combo／slider 回 default
    setBool.b = true
    local reset = env.controls(function(el) return el._sec and el.title == T("UI_MinidoracatMiniMap_StudioResetCategory") end)[1]
    reset.onclick(reset.target, reset)
    check(setBool.a == true and setBool.b == true and setBool.combo == 2 and setBool.vol == 48,
        "A7 reset writes defaults, skips the nil-default tick")
    -- 控制項順序：圖層區塊 → ticks → combos → sliders → actions → 重設
    s.selectSection("addon_AutoDrive")
    local kinds = {}
    for _, el in ipairs(env.studio().controls) do
        local t = env.type(el)
        if el._entry then
            local k = t == "MinidoracatUICheckbox" and "tick" or t == "MinidoracatUIDropdown" and "combo"
                or t == "MinidoracatUISliderRow" and "slider" or "action"
            if kinds[#kinds] ~= k then kinds[#kinds + 1] = k end
        elseif el._sec and t == "MinidoracatUIButton" then kinds[#kinds + 1] = "reset" end
    end
    checkEq(table.concat(kinds, ","), "tick,combo,slider,action,reset", "A8 addon control order")
    -- 只有 actions 的分類（地圖錶管理）沒有可重設的值：照樣放動作鈕，不放重設鈕
    s.selectSection("addon_WatchAdmin")
    check(env.controls(function(el) return el.title == "UI_WatchAdminOpen" end)[1] ~= nil
        and env.controls(function(el) return el._sec and el.title == T("UI_MinidoracatMiniMap_StudioResetCategory") end)[1] == nil,
        "A9 action-only section shows its action but no reset button")
end

-- ── 搜尋：addon tick＝可切的勾選、slider／action／圖層＝跳轉 ────────────────────────
do
    s.search._entry:setText("UI_ADNoDefault")
    s.search:prerender()
    env.frame()
    local hit = env.controls(function(el) return el._hit ~= nil end)[1]
    check(hit and env.type(hit) == "MinidoracatUICheckbox" and hit._hit.mode == "addon", "S1 addon tick search result")
    hit:forceClick()
    checkEq(setBool.b, false, "S1 search tick writes through set")
    s.search._entry:setText("ui_vmbound")
    s.search:prerender()
    env.frame()
    hit = env.controls(function(el) return el._hit ~= nil end)[1]
    check(hit and hit._hit.kind == "navigate", "S2 layer label is searchable")
    hit.onclick(hit.target, hit)
    env.frame()
    checkEq(env.studio().selected, "addon_VM", "S2 layer result jumps to the add-on section")
end

-- ── 熱更新：開著時重註冊＝下一幀重建導覽與內容 ────────────────────────────────
do
    API.registerSettingsSection("Plain", { label = "UI_PlainRenamed", icon = "star" })
    env.frame()
    s.nav:prerender()
    local label
    for _, row in ipairs(s.nav._rows) do if row.id == "addon_Plain" then label = row.label .. "/" .. row.icon end end
    checkEq(label, "UI_PlainRenamed/star", "H1 re-registration while open refreshes the nav")
end

io.write(string.format("test_addon_settings: %d assertions, %d failures\n", assertions, failures))
if failures > 0 then os.exit(1) end
io.write("test_addon_settings: PASS (registry v1-v5, groups/order/visible, v5 layer blocks, controls, reset, search)\n")
