-- Map Display Settings source-extracted pure regression checks.
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
local function extract(name)
    return assert(source:match("%-%- test:" .. name .. ":start\n(.-)\n%-%- test:"
        .. name .. ":end"), "missing " .. name .. " test block")
end

local layoutChunk, layoutErr = compile(extract("settings%-studio%-layout") .. "\n" .. [[
return studioPaneLayout
]])
assert(layoutChunk, layoutErr)
local layout = layoutChunk()
local wide = layout(1200, 440, 16)
checkEq(wide.mode, "wide", "wide viewport uses two panes")
check(wide.navW > 0 and wide.inspectorW >= 300, "wide panes have usable widths")
check(wide.windowW <= 1192, "wide panel stays inside viewport")
local narrow = layout(560, 440, 16)
checkEq(narrow.mode, "narrow", "narrow viewport uses one pane")
checkEq(narrow.navW, 0, "narrow layout has no side nav width")
check(narrow.windowW <= 552 and narrow.inspectorW == narrow.windowW,
    "narrow panel stays inside viewport")
local largeFont = layout(784, 440, 38, 400)
checkEq(largeFont.mode, "narrow",
    "large font and long labels force single pane instead of clipping navigation")
check(source:find('showBack = pane.mode == "narrow"', 1, true) ~= nil,
    "narrow inspector exposes back action")

local sliderChunk, sliderErr = compile(extract("settings%-studio%-slider") .. "\n" .. [[
return studioSliderRatio
]])
assert(sliderChunk, sliderErr)
local sliderRatio = sliderChunk()
checkEq(sliderRatio(50, 0, 100), 0.5, "modern slider ratio preserves midpoint")
check(sliderRatio(-5, 0, 100) == 0 and sliderRatio(150, 0, 100) == 1,
    "modern slider ratio clamps to endpoints")
check(sliderRatio(0 / 0, 0, 100) == 0 and sliderRatio(10, 10, 10) == 0,
    "modern slider ratio rejects NaN and degenerate ranges")

local queryChunk, queryErr = compile(extract("settings%-studio%-query") .. "\n" .. [[
return studioNormalizeQuery, studioQuery
]])
assert(queryChunk, queryErr)
local normalize, query = queryChunk()
local index = {
    { low = "animal icons", id = "animals" },
    { low = "vehicle icon size", id = "vehicles" },
    { low = "map size", id = "appearance" },
}
checkEq(normalize("  ICON  "), "icon", "query trims and folds case")
checkEq(query(index, "   "), nil, "empty query browses categories")
local hits = query(index, "icon")
checkEq(#hits, 2, "non-empty query searches across categories")
checkEq(hits[1].id, "animals", "query keeps category order")
checkEq(#query(index, "missing"), 0, "non-empty miss returns empty results")

local adminChunk, adminErr = compile([[
local state = { can = false, allowed = false, lastPn = nil }
local UNIFIED_SECTIONS = { { id = "layers" }, { id = "perf" } }
local Policy = {
    hasCanSeeAll = function(pn) state.lastPn = pn; return state.can end,
    readBool = function(name, default)
        if name == "AllowAdminTacticalView" then return state.allowed end
        return default
    end,
}
]] .. extract("settings%-studio%-admin") .. "\n" .. [[
return adminSectionEligible, adminSectionSync, UNIFIED_SECTIONS, state
]])
assert(adminChunk, adminErr)
local adminEligible, adminSync, adminSections, adminState = adminChunk()
check(not adminEligible(0) and not adminSync(0),
    "admin section stays absent without CanSeeAll")
adminState.can = true
check(not adminEligible(0) and not adminSync(0),
    "admin section stays absent while server policy denies it")
adminState.allowed = true
check(adminSync(1) and adminSections[2].id == "admin"
    and adminSections[3].id == "perf" and adminState.lastPn == 1,
    "eligible split-screen slot inserts admin section before performance")
check(not adminSync(1), "admin section insertion is idempotent")
adminState.allowed = false
check(adminSync(1) and adminSections[2].id == "perf",
    "revoked server permission removes admin section live")
check(not adminSync(1), "admin section removal is idempotent")
check(source:find("Policy.setLocalTactical", 1, true) ~= nil
    and source:find("Policy.setLocalPrivacy", 1, true) ~= nil
    and source:find("sub.enable = privacyAllowed and tacticalOn", 1, true) ~= nil,
    "admin builder wires tactical master and gated privacy child")
check(source:find("sandboxDist(entry.capBy, ctx.pn)", 1, true) ~= nil,
    "admin distance bypass remains per-player and client slider still tightens")
check(source:find("if adminSectionSync(pn) and win._searchIndex then", 1, true) ~= nil,
    "unified rebuild synchronizes dynamic admin membership before rebuilding rows")
check(source:find('studioIndexAdd(index, sec, "UI_MinidoracatMiniMap_AdminTactical", "navigate")', 1, true) ~= nil
    and source:find('studioIndexAdd(index, sec, "UI_MinidoracatMiniMap_AdminPrivacy", "navigate")', 1, true) ~= nil,
    "admin search results navigate to the gated section instead of exposing raw checkboxes")
check(source:find("Policy.setLocalTactical(target._playerNum or 0, false)", 1, true) ~= nil,
    "admin category reset clears only the owning split-screen slot")
check(source:find("studioSearchEnabled(hit, target._playerNum or 0)", 1, true) ~= nil
    and source:find("studioSearchEnabled(hit, ctx.pn)", 1, true) ~= nil,
    "admin-aware search enablement receives the active player slot")

local effectiveChunk, effectiveErr = compile([[
local gates, livestock = {}, 2
local function sandboxGate(name, default)
    if gates[name] == nil then return default end
    return gates[name]
end
local function livestockVisibilityMode() return livestock end
]] .. extract("settings%-studio%-effective") .. "\n" .. [[
return studioSearchEnabled,
    function(name, value) gates[name] = value end,
    function(value) livestock = value end
]])
assert(effectiveChunk, effectiveErr)
local searchEnabled, setGate, setLivestock = effectiveChunk()
local sectionHit = { sec = { gate = "AllowAnimalDots" }, entry = { id = "AnimalWild" } }
check(searchEnabled(sectionHit), "search boolean enabled when section gate allows")
setGate("AllowAnimalDots", false)
check(not searchEnabled(sectionHit), "search boolean disabled by section gate")
setGate("AllowAnimalDots", true)
local entryHit = { sec = {}, entry = { id = "WMVehicleDots", gate = "AllowVehicleDots" } }
setGate("AllowVehicleDots", false)
check(not searchEnabled(entryHit), "search boolean disabled by entry gate")
setLivestock(4)
local livestockHit = { sec = {}, entry = { id = "AnimalLivestock" } }
check(not searchEnabled(livestockHit), "livestock mode four disables livestock search control")

local masterSource = extract("settings%-studio%-master")
local masterChunk, masterErr = compile([[
local values = {}
local function getBoolOption(id, default)
    if values[id] == nil then return default end
    return values[id]
end
]] .. masterSource .. "\n" .. [[
return studioMasterValue, function(id, value) values[id] = value end
]])
assert(masterChunk, masterErr)
local masterValue, setMasterValue = masterChunk()
check(masterValue({ id = "PoiIcons", default = true }),
    "single-option nav master reads its production default")
local animalMaster = { members = {
    { id = "AnimalWild", default = false },
    { id = "AnimalLivestock", default = false },
} }
check(not masterValue(animalMaster), "animal group pill is off when both members are off")
setMasterValue("AnimalWild", true)
check(masterValue(animalMaster), "animal group pill is on when either member is on")

local titlebarChunk, titlebarErr = compile([[
local iconAvailable = true
local amber, muted, primary = { id = "amber" }, { id = "muted" }, { id = "primary" }
ISButton = { render = function(self) self.baseRender = (self.baseRender or 0) + 1 end }
UIFont = { Medium = "Medium" }
Core = { Skin = {
    COLORS = { ACCENT_AMBER = amber, TEXT_MUTED = muted, TEXT_PRIMARY = primary },
    icon = function(self, key, x, y, size, color)
        self.iconKey, self.iconSize, self.iconColor = key, size, color
        return iconAvailable
    end,
} }
local function getTextManager()
    return { getFontHeight = function() return 18 end }
end
local function getText(key) return key end
]] .. extract("settings%-studio%-titlebar") .. "\n" .. [[
return studioLockButtonRender, studioCloseButtonRender,
    function(value) iconAvailable = value end, amber, muted, primary
]])
assert(titlebarChunk, titlebarErr)
local renderLock, renderClose, setIconAvailable, amber, muted, primary = titlebarChunk()
local function titlebarButton(locked, mouseOver)
    return {
        _studioLocked = locked, mouseOver = mouseOver, width = 26, height = 26,
        drawTextCentre = function(self, text) self.fallback = text end,
    }
end
local lockedButton = titlebarButton(true, false)
renderLock(lockedButton)
check(lockedButton.iconKey == "lock" and lockedButton.iconSize == 20
    and lockedButton.iconColor == amber and lockedButton.baseRender == 1,
    "locked titlebar button uses 20px amber closed lock")
local unlockedButton = titlebarButton(false, false)
renderLock(unlockedButton)
check(unlockedButton.iconKey == "unlock" and unlockedButton.iconColor == muted,
    "unlocked titlebar button uses muted open lock")
local hoverButton = titlebarButton(false, true)
renderLock(hoverButton)
check(hoverButton.iconKey == "unlock" and hoverButton.iconColor == primary,
    "unlocked hover keeps open shape and changes to primary color")
setIconAvailable(false)
local fallbackButton = titlebarButton(false, false)
renderLock(fallbackButton)
check(fallbackButton.fallback == "U" and fallbackButton.baseRender == 1,
    "missing unlock asset falls back to visible U")
setIconAvailable(true)
local closeButton = titlebarButton(false, false)
renderClose(closeButton)
check(closeButton.iconKey == "close" and closeButton.iconColor == muted,
    "close button uses the framework close icon")

local liveChunk, liveErr = compile([[
local gates = { AllowZombieDots = true, AllowAnimalDots = true, AllowVehicleDots = true }
local caps, livestock = {}, 2
local revision, adminEligible, lastAdminPn = 0, false, nil
local Policy = { getRevision = function() return revision end }
local function adminSectionEligible(pn)
    lastAdminPn = pn
    return adminEligible
end
local UNIFIED_SLIDERS = { distance = { { capBy = "A" }, { capBy = "B" } } }
local function sandboxGate(name, default)
    if gates[name] == nil then return default end
    return gates[name]
end
local function sandboxDist(name) return caps[name] end
local function livestockVisibilityMode() return livestock end
]] .. extract("settings%-studio%-live") .. "\n" .. [[
return studioLiveSettingsDirty,
    function(name, value) gates[name] = value end,
    function(name, value) caps[name] = value end,
    function(value) livestock = value end,
    function(value) revision = value end,
    function(value) adminEligible = value end,
    function() return lastAdminPn end
]])
assert(liveChunk, liveErr)
local liveDirty, setLiveGate, setCap, setLiveLivestock, setRevision,
    setLiveAdmin, getLastAdminPn = liveChunk()
local liveWin = {}
check(liveDirty(liveWin), "live signature seeds once")
check(not liveDirty(liveWin), "unchanged live signature does not rebuild")
setLiveGate("AllowZombieDots", false)
check(liveDirty(liveWin) and not liveDirty(liveWin), "gate transition dirties exactly once")
setCap("A", 300)
check(liveDirty(liveWin) and not liveDirty(liveWin), "distance cap transition dirties exactly once")
setLiveLivestock(4)
check(liveDirty(liveWin) and not liveDirty(liveWin), "livestock transition dirties exactly once")
setRevision(1)
check(liveDirty(liveWin) and not liveDirty(liveWin),
    "policy revision transition dirties exactly once")
setLiveAdmin(true)
check(liveDirty(liveWin) and not liveDirty(liveWin),
    "role/admin eligibility transition dirties exactly once")
liveWin._playerNum = 2
setLiveAdmin(false)
check(liveDirty(liveWin) and getLastAdminPn() == 2,
    "live admin eligibility uses the settings window owner slot")

local resetChunk, resetErr = compile([[
local values, addonValues = {}, {}
local engine = {
    [0] = { Isometric = true, Symbols = false, RemoteSymbols = true },
    [2] = { Isometric = false, Symbols = true, RemoteSymbols = false },
}
local stats = { apply = 0, save = 0, rebuild = 0, engineSets = 0 }
local modOptions = {
    getOption = function(_, id)
        return { setValue = function(_, value) values[id] = value end }
    end,
    apply = function()
        stats.apply = stats.apply + 1
        engine[0].Symbols = true -- production applyToggleOptions 只連帶操作 P0
    end,
}
local PZAPI = { ModOptions = { save = function() stats.save = stats.save + 1 end } }
local ZOMBIE_MASTER = { id = "ZombieDots", default = false }
local UNIFIED_ZOMBIE_COMBOS = {
    { id = "ZombieColor", default = 3 }, { id = "ZombieMax", default = 2 },
}
local UNIFIED_SLIDERS = { zombie = { { id = "ZombieSize", default = 5 } } }
local function addonWrite(entry, value) addonValues[entry.label] = value end
local function unifiedRebuild() stats.rebuild = stats.rebuild + 1 end
local function getSpecificPlayer(pn) return engine[pn] and {} or nil end
local function getPlayerMiniMap(pn) return engine[pn] and {} or nil end
local function unifiedEngineGet(name, pn) return engine[pn][name] end
local function unifiedEngineSet(name, value, pn)
    engine[pn][name] = value
    stats.engineSets = stats.engineSets + 1
end
]] .. extract("settings%-studio%-reset") .. "\n" .. [[
return studioResetSection, values, addonValues, stats, engine
]])
assert(resetChunk, resetErr)
local resetSection, resetValues, addonValues, resetStats, engine = resetChunk()
resetSection({ _playerNum = 2 }, { _studioSec = { id = "zombie" } })
check(resetValues.ZombieDots == false and resetValues.ZombieColor == 3
    and resetValues.ZombieMax == 2 and resetValues.ZombieSize == 5,
    "category reset writes every production default in one batch")
check(resetStats.apply == 1 and resetStats.save == 1 and resetStats.rebuild == 1,
    "category reset applies and saves once, then rebuilds")
check(engine[0].Isometric == true and engine[0].Symbols == false
    and engine[0].RemoteSymbols == true
    and engine[2].Isometric == false and engine[2].Symbols == true
    and engine[2].RemoteSymbols == false and resetStats.engineSets == 6,
    "category reset restores every existing local mini-map after P0-only apply")
resetSection({}, { _studioSec = { id = "addon_x", addon = {
    ticks = { { label = "show", default = true } },
    combos = { { label = "width", default = 2 } },
} } })
check(addonValues.show == true and addonValues.width == 2,
    "addon category reset delegates declared defaults")
check(resetStats.apply == 1 and resetStats.save == 1 and resetStats.rebuild == 2,
    "addon reset leaves host ModOptions untouched and rebuilds once")
check(source:find('studioResetId("ClientZoneDisplayDistance"', 1, true) == nil,
    "zones reset never changes the Distance category slider")

local required = { "layers", "poicat", "distance", "zombie", "animals",
    "vehicles", "worldmap", "appearance", "perf" }
local sections = assert(source:match("local UNIFIED_SECTIONS = {(.-)\n}"),
    "missing section table")
local builders = assert(source:match("local UNIFIED_BUILDERS = {(.-)\n}"),
    "missing builder table")
for i = 1, #required do
    local id = required[i]
    check(sections:find('id = "' .. id .. '"', 1, true) ~= nil,
        "built-in section reachable: " .. id)
    check(builders:find(id .. " = unifiedBuild", 1, true) ~= nil,
        "built-in builder reachable: " .. id)
end

local entryCreates = 0
for _ in source:gmatch("ISTextEntryBox:new%(") do entryCreates = entryCreates + 1 end
checkEq(entryCreates, 1, "exactly one settings search field")
check(source:find("_searchEntry:focus", 1, true) == nil, "settings search never autofocuses")
check(source:find("rawQuery ~= self._lastRawQuery", 1, true) ~= nil,
    "unchanged search text skips per-frame normalization allocations")
check(source:find("settingsUI:removeFromUIManager()", 1, true) ~= nil,
    "session reset removes the old Studio window from UIManager")
check(source:find("UNIFIED_LANE", 1, true) == nil, "old lane map removed")
check(source:find("unifiedExpand", 1, true) == nil, "old accordion state removed")
check(source:find("normalized.lane", 1, true) == nil, "addon lane never stored")
local animalsAt = sections:find('id = "animals"', 1, true)
local vehiclesAt = sections:find('id = "vehicles"', 1, true)
local animalsSection = animalsAt and sections:sub(animalsAt, vehiclesAt and vehiclesAt - 1 or #sections)
check(animalsSection and animalsSection:find('gate = "AllowAnimalDots"', 1, true) ~= nil,
    "animals section retains its server gate")
check(source:find("tick.enable = enabled", 1, true) ~= nil,
    "search result tick exposes effective disabled state")
check(source:find("_searchEntry:setHeight(searchH)", 1, true) ~= nil,
    "search entry height follows the active font")
check(masterSource:find("unifiedRebuild(target)", 1, true) ~= nil,
    "master pill rebuilds all alternate control surfaces")
check(source:find('studioIndexAdd(index, sec, ZONE_MASTER.label, "boolean", "mod", ZONE_MASTER)', 1, true) ~= nil,
    "zones master is reachable through cross-category search")

check(source:find('e.id ~= "ZoneLayer"', 1, true) ~= nil,
    "ZoneLayer search has one canonical hit instead of duplicate checkboxes")
check(source:find("local painted = Skin and Skin.toggle", 1, true) ~= nil,
    "failed shared toggle painter falls back to the local visible renderer")
check(source:find("slider.render = unifiedSliderRender", 1, true) ~= nil,
    "native slider interaction is retained while render uses the modern painter")
local addToUiAt = source:find("win:addToUIManager()", 1, true)
local closeStyleAt = source:find("studioStyleCloseButton(win.closeButton)", 1, true)
check(addToUiAt ~= nil and closeStyleAt ~= nil and closeStyleAt > addToUiAt
    and source:find('studioTitleBarIcon(self, "close"', 1, true) ~= nil
    and source:find("Skin.icon(self, key,", 1, true) ~= nil,
    "close and lock chrome are styled after titlebar children exist")
check(source:find("win.titleBarFont = UIFont.Medium", 1, true) ~= nil
    and source:find("win.titleFontHgt = getTextManager():getFontHeight(UIFont.Medium)", 1, true) ~= nil
    and source:find("math.min(20, self.width - 4, self.height - 4)", 1, true) ~= nil,
    "Medium titlebar enlarges title and chrome icons together")
check(source:find("master = POI_MASTER_TICKS[1]", 1, true) ~= nil
    and source:find("master = ANIMAL_NAV_MASTER", 1, true) ~= nil
    and source:find("entry.members", 1, true) ~= nil,
    "resource and animal sections expose functional nav master pills")
check(source:find("unifiedHeaderSummary", 1, true) == nil
    and source:find("studioCacheSummaries", 1, true) == nil
    and source:find("_summaries", 1, true) == nil
    and source:find("spec.summary", 1, true) == nil,
    "all navigation summary and count paths are removed")
check(source:find("UI_MinidoracatMiniMap_StudioResetCategory", 1, true) ~= nil
    and source:find("reset._studioSec = sec", 1, true) ~= nil,
    "every configurable inspector receives a bottom-right reset action")
check(source:find("measure.fontH * 34", 1, true) ~= nil
    and source:find("measure.rowH * 24", 1, true) ~= nil,
    "default Studio width and height are larger but font-derived")
local dividerCalls = 0
for _ in source:gmatch("unifiedAddDivider%(ctx%)") do dividerCalls = dividerCalls + 1 end
check(dividerCalls >= 3, "performance explanation uses clear visual separators")
check(source:find("Skin.slider", 1, true) ~= nil,
    "slider drawing routes through the shared framework painter seam")
check(source:find('addTickBox("ZoneNames"', 1, true) ~= nil
    and source:find('id = "ZoneNames", default = true', 1, true) ~= nil
    and source:find('studioResetId("ZoneNames", true)', 1, true) ~= nil,
    "custom-zone text toggle is registered, searchable, and resettable")
check(source:find("_scrollBySection%[win._renderedScrollKey%]", 1) ~= nil,
    "live rebuild preserves inspector/search scroll")
check(source:find("pcall(studioRebuildDirty, self, structuralDirty)", 1, true) ~= nil
    and source:find("or self._studioRebuildRetry", 1, true) ~= nil,
    "failed live rebuild is logged and retried instead of consuming the dirty signature")
local EXPECTED_ASSERTIONS = 98
if assertions ~= EXPECTED_ASSERTIONS then
    print("assertion count mismatch: expected " .. EXPECTED_ASSERTIONS
        .. ", actual " .. assertions)
    os.exit(1)
end
print("settings studio assertions " .. assertions .. ", failures " .. failures)
if failures > 0 then os.exit(1) end
