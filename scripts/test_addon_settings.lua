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
local UNIFIED_SECTIONS = { { id = "layers" }, { id = "perf" } }
local settingsUI = { visible = false }
function settingsUI:isVisible() return self.visible end
local rebuildCalls = 0
local function unifiedRebuild() rebuildCalls = rebuildCalls + 1 end
local indexCalls = 0
local function studioBuildIndex() indexCalls = indexCalls + 1; return {} end
MinidoracatMiniMapAPI = {}
]] .. registryBody .. "\n" .. [=[
return {
    api = MinidoracatMiniMapAPI,
    sections = UNIFIED_SECTIONS,
    registry = addonSettingsById,
    ui = settingsUI,
    rebuilds = function() return rebuildCalls end,
    indexBuilds = function() return indexCalls end,
    messages = messages,
}
]=])
assert(registryChunk, registryErr)
local registry = registryChunk()
local api = registry.api

checkEq(api.settingsApiVersion, 2, "settings API version")
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
    return combo
end
local function unifiedAddBtn(ctx, x, yy, w, labelText, fn, tooltip)
    local b = { kind = "btn", label = labelText, callback = fn, tooltip = tooltip,
        enable = true }
    rows[#rows + 1] = b
    return b
end
]] .. callbacksBody .. "\n" .. builderBody .. "\n" .. [=[
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
checkEq(combo.tooltip, "T:UI_Width_tip", "combo tooltip wired")
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
    actions = { { label = "UI_Copy" } },
} }
]] .. indexBody .. "\nreturn added")
assert(indexChunk, indexErr)
local added = indexChunk()
checkEq(#added, 3, "addon index covers ticks, combos, actions")
checkEq(added[3].kind, "navigate", "actions are searchable navigate hits")
checkEq(added[3].first.label, "UI_Copy", "action label indexed")
local EXPECTED_ASSERTIONS = 75
if assertions ~= EXPECTED_ASSERTIONS then
    print("assertion count mismatch: expected " .. EXPECTED_ASSERTIONS
        .. ", actual " .. assertions)
    os.exit(1)
end
print("addon settings assertions " .. assertions .. ", failures " .. failures)
if failures > 0 then os.exit(1) end
