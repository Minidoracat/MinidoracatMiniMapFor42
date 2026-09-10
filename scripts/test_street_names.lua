-- Name-only translation must never replace source geometry or a third-party name.
local path = arg[1] or "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/client/MinidoracatMiniMap_StreetData.lua"
local source = assert(io.open(path, "rb")):read("*a")
local keyA, keyB = "UI_Test_A-Road", "UI_Test_B-Road"
local lang, translations, active, data, log = "CH", {}, {}, {}, {}
local visibleClears, scratchClears, created = 0, 0, 0
local loaderEffect
local function list(items)
    return { size = function() return #items end, get = function(_, i) return items[i + 1] end }
end
local function street(name, x)
    return {
        name = name, splitName = name, x = x, y = 8000, width = 8, count = 3,
        getTranslatedText = function(self) return self.name end,
        setTranslatedText = function(self, value) self.name = value:match("^%s*$") and "" or value end,
        clipToObscuredCells = function(self) self.splitName = self.name end,
    }
end
local function map(scratch)
    local loaded, shown = {}, {}
    local api = {
        getStreetDataByRelativeFileName = function(_, rel) return loaded[rel] end,
        addStreetData = function(_, rel)
            if data[rel] and not loaded[rel] then
                loaded[rel] = data[rel]
                for _, st in ipairs(data[rel]) do shown[#shown + 1] = st.splitName end
            end
        end,
        clearStreetData = function()
            if scratch then scratchClears = scratchClears + 1 else visibleClears = visibleClears + 1 end
        end,
    }
    local ui = { javaObject = { getAPIv3 = function() return { getStreetsAPI = function() return api end } end } }
    return ui, shown, api
end
local function setup(packs)
    lang, translations, active, data, log = "CH", {}, { "MapA", "MapB" }, {}, {}
    visibleClears, scratchClears, created = 0, 0, 0
    loaderEffect = nil
    MinidoracatMiniMapCore = { ready = true, registeredPacks = packs }
    MapUtils = { initDirectoryStreetData = function(ui, dir)
        ui.javaObject:getAPIv3():getStreetsAPI():addStreetData(dir .. "/streets.xml")
        if loaderEffect then loaderEffect() end
    end }
    Translator = { getLanguage = function() return { name = function() return lang end } end }
    getActivatedMods = function() return list(active) end
    fileExists = function(rel) return data[rel] ~= nil end
    getTextOrNull = function(key) return translations[lang] and translations[lang][key] end
    getStreets = function(raw) return list(raw) end
    UIWorldMap = { new = function()
        created = created + 1
        local ui = map(true)
        return ui.javaObject
    end }
    local oldPrint = print
    print = function(message) log[#log + 1] = message end
    assert(load(source, "street-names"))()
    print = oldPrint
end
local function pack(dir, mod, names)
    return { owner = "Pack", entries = { { mapDir = dir, mapMod = mod, streetNames = names } } }
end
local function open(dir)
    local ui, shown = map(false)
    MapUtils.initDirectoryStreetData(ui, "media/maps/" .. dir)
    return ui, shown
end

setup({ pack("A", "MapA", { Main = keyA }), pack("B", "MapB", { Main = keyB }) })
translations = { CH = { [keyA] = "A translated", [keyB] = "B translated" }, JP = { [keyA] = "A Japanese" } }
local a, unknown, other = street("Main", 120), street("New Road", 240), street("Main", 360)
data["media/maps/A/streets.xml"] = { a, unknown }
data["media/maps/B/streets.xml"] = { other }
local ui, shown = open("A")
assert(shown[1] == "A translated" and shown[2] == "New Road", "translate known name; new road stays present")
local _, shownB = open("B")
assert(shownB[1] == "B translated", "same name in different map stays scoped")
assert(a.x == 120 and a.y == 8000 and a.width == 8 and a.count == 3, "geometry and width unchanged")
assert(a.name == "Main" and a.splitName == "Main", "raw and split original names restored after display copy")
assert(MinidoracatMiniMapCore.streetDisplayName(a.name, "A") == "A translated", "navigation display resolves from original")
-- Upstream coordinates are live inputs, never a key into baked geometry.
a.x = 512
local _, moved = open("A")
assert(a.x == 512 and moved[1] == "A translated", "coordinate update does not invalidate translation")
lang = "JP"
local _, japanese = open("A")
assert(japanese[1] == "A Japanese" and japanese[2] == "New Road", "new UI gets current language")
assert(shown[1] == "A translated", "existing UI copies are not mutated")
lang = "EN"
local _, english = open("A")
assert(english[1] == "Main" and a.name == "Main", "restore source after language change")
lang = "CH"
open("A")
a.name = "Third party name"
a:clipToObscuredCells()
local _, thirdParty = open("A")
assert(a.name == "Third party name", "do not overwrite foreign rename")
assert(thirdParty[1] == "Third party name", "foreign display name preserved")
assert(MinidoracatMiniMapCore.streetDisplayName(a.name, "A") == "Third party name", "do not invent foreign alias")
assert(visibleClears == 0 and scratchClears == created, "cleanup is restricted to temporary maps")

setup({ pack("A", "MapA", { Main = keyA }), pack("A", "MapB", { Main = keyB }) })
translations.CH = { [keyA] = "Wrong A", [keyB] = "Wrong B" }
data["media/maps/A/streets.xml"] = { street("Main", 120) }
local _, conflict = open("A")
assert(conflict[1] == "Main", "ambiguous map variants must not guess")
active = { "MapB" }
local _, selected = open("A")
assert(selected[1] == "Wrong B", "single active variant selects its own dictionary")

setup({ pack("A", "MapA", { Main = keyA }) })
translations.CH = { [keyA] = keyA }
data["media/maps/A/streets.xml"] = { street("Main", 120) }
local _, missing = open("A")
assert(missing[1] == "Main", "missing translation must not render a UI key")
local preloaded, preShown, preAPI = map(false)
preAPI:addStreetData("media/maps/A/streets.xml")
translations.CH[keyA] = "New translation"
MapUtils.initDirectoryStreetData(preloaded, "media/maps/A")
assert(preShown[1] == "Main" and data["media/maps/A/streets.xml"][1].name == "Main", "never rebuild an already populated player map")
assert(visibleClears == 0)

setup({ pack("A", "MapA", { Main = keyA }) })
translations.CH = { [keyA] = "Translated" }
local failing = street("Main", 120)
data["media/maps/A/streets.xml"] = { failing }
loaderEffect = function() error("original loader failed") end
local loaded, failure = pcall(open, "A")
assert(not loaded and failure:find("original loader failed", 1, true), "original loader failure remains observable")
assert(failing.name == "Main" and failing.splitName == "Main", "failed loader still restores source")
assert(visibleClears == 0 and scratchClears == created, "failed loader releases only scratch")
loaderEffect = function() failing.name = "Foreign override" end
open("A")
assert(failing.name == "Foreign override", "restore must not overwrite changes made by an inner third-party loader")
assert(failing.splitName == "Foreign override", "source split no longer retains our transient name")

setup({ pack("A", "MapA", { Main = keyA }) })
translations.CH = { [keyA] = "Translated" }
local brokenClip = street("Main", 120)
brokenClip.clipToObscuredCells = function(self)
    if self.name == "Translated" then error("clip failed") end
    self.splitName = self.name
end
data["media/maps/A/streets.xml"] = { brokenClip }
local _, fallback = open("A")
assert(fallback[1] == "Main" and brokenClip.name == "Main", "prepare failure restores before original fallback")
assert(visibleClears == 0 and scratchClears == created, "prepare failure cleans scratch")

setup({ pack("A", "MapA", { Main = keyA, Second = keyB }) })
translations.CH = { [keyA] = "Second", [keyB] = "Third" }
data["media/maps/A/streets.xml"] = { street("Main", 120), street("Second", 240) }
local nestedShown
loaderEffect = function()
    loaderEffect = nil
    local nestedUI
    nestedUI, nestedShown = open("A")
end
open("A")
assert(nestedShown[1] == "Second", "nested load must not translate a transient name twice")
assert(data["media/maps/A/streets.xml"][1].name == "Main", "outermost load restores true original")

setup({ pack("A", "MapA", { Main = keyA }) })
translations.CH = { [keyA] = " \t " }
local blank = street("Main", 120)
data["media/maps/A/streets.xml"] = { blank }
local _, blankShown = open("A")
assert(blank.name == "Main" and blankShown[1] == "Main", "whitespace translation cannot erase source or label")
print("test_street_names: PASS (geometry, scope, variants, language, source-name retention, foreign changes, missing translations)")
