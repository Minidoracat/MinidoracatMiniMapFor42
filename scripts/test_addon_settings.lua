-- MiniMap addon client-settings API / builder 離線回歸。
local sourcePath = arg[1]
    or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_Settings.lua"

local file = assert(io.open(sourcePath, "rb"))
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

local registryBody = assert(source:match(
    "%-%- test:addon%-settings%-registry:start\n(.-)\n%-%- test:addon%-settings%-registry:end"),
    "missing addon settings registry test block")
local registryChunk, registryErr = compile([[
local messages = {}
local function print(message) messages[#messages + 1] = message end
local addonSettingsById = {}
local addonSectionOrder = {}
local UNIFIED_SECTIONS = { { id = "layers" }, { id = "perf" } }
local settingsUI = { visible = false }
function settingsUI:isVisible() return self.visible end
local rebuildCalls = 0
local function unifiedRebuild() rebuildCalls = rebuildCalls + 1 end
local indexCalls = 0
local function studioBuildIndex() indexCalls = indexCalls + 1; return {} end
MinidoracatMiniMapAPI = {}
local layerCalls = {}
local Core = { registerMarkerLayers = function(owner, layers)
    layerCalls[#layerCalls + 1] = { owner = owner, layers = layers }
end }
]] .. registryBody .. "\n" .. [=[
return {
    api = MinidoracatMiniMapAPI,
    sections = UNIFIED_SECTIONS,
    registry = addonSettingsById,
    order = addonSectionOrder,
    ui = settingsUI,
    rebuilds = function() return rebuildCalls end,
    indexBuilds = function() return indexCalls end,
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
checkEq(#registry.sections, 2, "invalid registrations do not append sections")

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
checkEq(#registry.sections, 3, "one valid section appended")
checkEq(registry.sections[2].id, "addon_OwnerA", "addon inserted before perf")
checkEq(registry.sections[3].id, "perf", "perf stays last")
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
checkEq(#registry.sections, 4, "different owner gets its own section")
checkEq(registry.sections[3].id, "addon_OwnerB", "second addon also before perf")
checkEq(registry.sections[4].id, "perf", "perf remains last after two addons")

local oldSection = registry.registry.OwnerA
check(api.registerSettingsSection("OwnerA", {
    label = "UI_A2", lane = "full", ticks = {
        { label = "UI_Show2", get = function() return true end, set = function() end },
    },
}), "same owner re-registers")
checkEq(#registry.sections, 4, "same owner replacement is idempotent")
checkEq(registry.registry.OwnerA, oldSection, "same section identity retained")
checkEq(oldSection.label, "UI_A2", "same owner updates label")
checkEq(oldSection.addon.lane, nil, "re-registration still ignores lane")
registry.ui.visible = true
local beforeRebuild = registry.rebuilds()
check(api.registerSettingsSection("OwnerA", {
    label = "UI_A3", ticks = {
        { label = "UI_Show3", get = function() return true end, set = function() end },
    },
}), "visible-window replacement succeeds")
checkEq(registry.rebuilds(), beforeRebuild + 1, "visible window rebuilds on registration")
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
checkEq(#registry.sections, 4, "invalid actions do not append sections")

local specC = {
    label = "UI_C",
    actions = {
        { label = "UI_Copy", tooltip = "UI_Copy_tip",
            run = function() end, enabled = function() return true end },
    },
}
local beforeIndex = registry.indexBuilds()
check(api.registerSettingsSection("OwnerC", specC), "valid action registers")
checkEq(registry.indexBuilds(), beforeIndex + 1,
    "action registration rebuilds search index")
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

local callbacksBody = assert(source:match(
    "%-%- test:addon%-settings%-callbacks:start\n(.-)\n%-%- test:addon%-settings%-callbacks:end"),
    "missing addon callbacks test block")
local builderBody = assert(source:match(
    "%-%- test:addon%-settings%-builder:start\n(.-)\n%-%- test:addon%-settings%-builder:end"),
    "missing addon builder test block")
local builderChunk, builderErr = compile([[
local errors = {}
local function print(message) errors[#errors + 1] = message end
local function getText(key) return "T:" .. key end
UIFont = { Small = 1 }
ISLabel = {}
function ISLabel:new(x, y, h, text) return { kind = "label", text = text } end
local rows = {}
local function unifiedAdd(ctx, element) rows[#rows + 1] = element; return element end
local function unifiedAddTick(ctx, x, y, w, label, checked, callback, arg)
    local tick = { kind = "tick", label = label, checked = checked,
        callback = callback, arg = arg }
    rows[#rows + 1] = tick
    return tick
end
ISComboBox = {}
function ISComboBox:new(x, y, w, h, target, callback, arg)
    local combo = { kind = "combo", callback = callback, arg = arg, options = {} }
    function combo:initialise() end
    function combo:addOption(text) self.options[#self.options + 1] = text end
    function combo:setToolTipMap(map) self.tooltip = map end
    return combo
end
local function unifiedAddBtn(ctx, x, yy, w, labelText, fn, tooltip)
    local b = { kind = "btn", label = labelText, callback = fn, tooltip = tooltip,
        enable = true }
    rows[#rows + 1] = b
    return b
end
local function utw(text) return #text * 6 end
-- 同 production unifiedAddSlider 的契約：methods 先蓋上、setCurrentValue(value, true) 不觸發回呼、
-- 改值經 doOnValueChange → onChange；onJoypadDirLeft／Right 同原版（±stepValue）
local function unifiedAddSlider(ctx, entry, maxV, value, valW, text, onChange, onCommit, methods)
    local label = unifiedAdd(ctx, { kind = "slabel", text = getText(entry.label) })
    local s = { kind = "slider", _entry = entry, maxValue = maxV, stepValue = entry.step,
        valW = valW, onCommit = onCommit }
    function s:doOnValueChange(v) self.shown = text(onChange(v, self)) end
    function s:getCurrentValue() return self.currentValue end
    function s:onJoypadDirRight() self:setCurrentValue(self.currentValue + self.stepValue) end
    function s:onJoypadDirLeft() self:setCurrentValue(self.currentValue - self.stepValue) end
    for k, fn in pairs(methods or {}) do s[k] = fn end
    s:setCurrentValue(value, true)
    s.shown = text(s:getCurrentValue())
    unifiedAdd(ctx, s)
    return s, label
end
]] .. callbacksBody .. "\nlocal ADDON_SLIDER_METHODS = { setCurrentValue = addonSliderSetValue }\n"
    .. builderBody .. "\n" .. [=[
return {
    build = unifiedBuildAddon,
    rows = rows,
    errors = errors,
    read = addonRead,
}
]=])
assert(builderChunk, builderErr)
local builder = builderChunk()
local tickValue, comboValue = true, 3
local spec = {
    ticks = { { label = "UI_Show", tooltip = "UI_Show_tip", default = false,
        get = function() return tickValue end,
        set = function(v) tickValue = v end } },
    combos = { { label = "UI_Width", tooltip = "UI_Width_tip", default = 2,
        items = { "UI_Thin", "UI_Normal", "UI_Thick" },
        get = function() return comboValue end,
        set = function(v) comboValue = v end } },
}
local ctx = { sec = { addon = spec }, curX = 0, curY = 0, laneW = 300,
    comboLabelW = 80, fontH = 12, rowH = 20, win = {} }
builder.build(ctx)
checkEq(#builder.rows, 3, "builder creates tick, label, combo")
local tick, combo = builder.rows[1], builder.rows[3]
check(tick.kind == "tick" and tick.checked == true, "tick getter initializes checked state")
checkEq(tick.tooltip, "T:UI_Show_tip", "tick tooltip wired")
check(combo.kind == "combo" and combo.selected == 3 and #combo.options == 3,
    "combo getter and items initialize control")
check(type(combo.tooltip) == "table" and combo.tooltip.defaultTooltip == "T:UI_Width_tip",
    "combo tooltip is a defaultTooltip map (vanilla ISComboBox ignores a plain string)")
comboValue = 0 / 0
builder.build(ctx)
checkEq(builder.rows[#builder.rows].selected, 2, "NaN combo getter falls back to default")
comboValue = 3
tick.callback(nil, 1, false, tick.arg)
checkEq(tickValue, false, "tick callback writes addon setting")
combo.selected = 1
combo.callback(nil, combo, combo.arg)
checkEq(comboValue, 1, "combo callback writes addon setting")
checkEq(builder.read(function() error("bad getter") end, 7), 7,
    "throwing getter falls back")
tick.arg.set = function() error("bad setter") end
local setterOk = pcall(tick.callback, nil, 1, true, tick.arg)
check(setterOk and #builder.errors == 1, "throwing setter is isolated and diagnosed")

local runPn, enabledPn, allow = nil, nil, true
spec.actions = {
    { label = "UI_Copy", tooltip = "UI_Copy_tip",
        run = function(pn) runPn = pn end,
        enabled = function(pn) enabledPn = pn; return allow end },
}
ctx.pn = 2
ctx.win._playerNum = 2
local rows = builder.rows
local function rebuildAddon()
    for i = #rows, 1, -1 do rows[i] = nil end
    builder.build(ctx)
end
rebuildAddon()
checkEq(#rows, 4, "builder adds action button after tick and combo")
local btn = rows[4]
check(btn.kind == "btn" and btn.label == "T:UI_Copy", "action button label")
checkEq(btn.tooltip, "T:UI_Copy_tip", "action button tooltip")
checkEq(btn.enable, true, "enabled true keeps button on")
checkEq(enabledPn, 2, "enabled receives window playerNum")
btn.callback(ctx.win, btn)
checkEq(runPn, 2, "run receives window playerNum")
allow = false
rebuildAddon()
btn = rows[4]
checkEq(btn.enable, false, "enabled false disables button")
runPn = "unset"
btn.callback(ctx.win, btn)
checkEq(runPn, "unset", "disabled action does not run")
spec.actions[1].enabled = function() error("bad enabled") end
rebuildAddon()
btn = rows[4]
checkEq(btn.enable, false, "throwing enabled fails closed")
runPn = "unset"
local enabledOk = pcall(btn.callback, ctx.win, btn)
check(enabledOk and runPn == "unset", "throwing enabled cannot reach run")
spec.actions[1].enabled = nil
spec.actions[1].run = function()
    error(setmetatable({}, { __tostring = function() error("bad tostring") end }))
end
rebuildAddon()
local errCount = #builder.errors
local runOk = pcall(rows[4].callback, ctx.win, rows[4])
check(runOk and #builder.errors == errCount + 1,
    "throwing run is isolated and diagnosed")

-- v4 滑條：初值對齊、拖曳／點擊／手把與鍵盤左右（皆經 setCurrentValue）只在換格時 set、夾在範圍、
-- 非 0 起點的格點、get／set 拋錯隔離
local volume, volumeSets = 47, {}
local volEntry = { label = "UI_Vol", tooltip = "UI_Vol_tip", min = 0, max = 100, step = 5,
    default = 50, fmt = "%d%%",
    get = function() return volume end,
    set = function(v) volumeSets[#volumeSets + 1] = v; volume = v end }
local oddEntry = { label = "UI_Odd", min = 1, max = 10, step = 2, default = 1, fmt = "%d",
    get = function() return 1 end, set = function() end }
ctx.sec = { addon = { sliders = { volEntry, oddEntry } } }
rebuildAddon()
local volLabel, vol, odd = rows[1], rows[2], rows[4]
check(volLabel.kind == "slabel" and volLabel.tooltip == "T:UI_Vol_tip" and vol.kind == "slider",
    "slider row has label with tooltip and slider")
check(vol.currentValue == 45 and vol.shown == "45%" and #volumeSets == 0,
    "getter value snapped to step without writing back")
check(vol.valW >= #"100%" * 6 + 10, "value column fits the widest formatted value")
vol:setCurrentValue(63)
check(vol.currentValue == 65 and volumeSets[1] == 65 and vol.shown == "65%",
    "drag value snaps to step and writes once")
vol:setCurrentValue(64)
checkEq(#volumeSets, 1, "same snapped cell does not write again")
vol:setCurrentValue(1000)
checkEq(volumeSets[#volumeSets], 100, "value above max clamps to max")
vol:setCurrentValue(-7)
checkEq(volumeSets[#volumeSets], 0, "value below min clamps to min")
vol:onJoypadDirRight()
checkEq(volumeSets[#volumeSets], 5, "right step writes next cell")
vol:onJoypadDirLeft()
checkEq(volumeSets[#volumeSets], 0, "left step writes previous cell")
vol:setCurrentValue(0 / 0)
checkEq(vol.currentValue, 50, "NaN value falls back to default")
odd:onJoypadDirRight()
checkEq(odd.currentValue, 3, "off-zero min keeps its own step grid")
odd:setCurrentValue(10)
checkEq(odd.currentValue, 10, "off-grid max stays reachable")
vol.disabled = true
local beforeDisabled = #volumeSets
vol:setCurrentValue(20)
checkEq(#volumeSets, beforeDisabled, "disabled slider ignores value changes")
volEntry.get = function() error("bad slider getter") end
volEntry.set = function() error("bad slider setter") end
rebuildAddon()
vol = rows[2]
checkEq(vol.currentValue, 50, "throwing slider getter falls back to default")
local sliderErrs = #builder.errors
local sliderSetOk = pcall(vol.setCurrentValue, vol, 80)
check(sliderSetOk and vol.currentValue == 80 and #builder.errors == sliderErrs + 1,
    "throwing slider setter is isolated and diagnosed")

local indexBody = assert(source:match(
    "%-%- test:addon%-settings%-index:start\n(.-)\n%s*%-%- test:addon%-settings%-index:end"),
    "missing addon settings index test block")
local indexChunk, indexErr = compile([[
local added = {}
local function studioIndexList(index, sec, list, kind, mode)
    added[#added + 1] = { n = #list, kind = kind, mode = mode, first = list[1] }
end
local index = {}
local sec = { addon = {
    ticks = { { label = "UI_T" } },
    combos = { { label = "UI_C" } },
    sliders = { { label = "UI_S" } },
    actions = { { label = "UI_Copy" } },
} }
]] .. indexBody .. "\nreturn added")
assert(indexChunk, indexErr)
local added = indexChunk()
checkEq(#added, 4, "addon index covers ticks, combos, sliders, actions")
check(added[3].kind == "navigate" and added[3].first.label == "UI_S",
    "sliders are searchable navigate hits")
checkEq(added[4].kind, "navigate", "actions are searchable navigate hits")
checkEq(added[4].first.label, "UI_Copy", "action label indexed")
local EXPECTED_ASSERTIONS = 156
if assertions ~= EXPECTED_ASSERTIONS then
    print("assertion count mismatch: expected " .. EXPECTED_ASSERTIONS
        .. ", actual " .. assertions)
    os.exit(1)
end
print("addon settings assertions " .. assertions .. ", failures " .. failures)
if failures > 0 then os.exit(1) end
