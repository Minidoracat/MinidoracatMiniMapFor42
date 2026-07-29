[h1]🗺️ Minidoracat MiniMap for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]✨ What is this[/h2]
Overlays a map image rendered from actual in-game visuals directly onto the B42
in-game world map, replacing the vanilla vector-line style. Built on the B42
engine's native ImagePyramid mechanism:
[list]
[*] Multi-level LOD — smooth zooming, no more stutter
[*] Engine-level texture caching and async loading — low VRAM usage
[*] What you see is what you get: buildings, roads and vegetation match the in-game look
[/list]

[h2]🧰 Features[/h2]
[list]
[*] [b]Image-based world map & corner mini-map[/b] — buildings, roads and vegetation match the in-game look; prefer vanilla? One toggle falls back to the vector style while every other feature keeps working
[*] [b]Mini-map hotkey[/b]: / (slash, right of M) by default (rebindable); works even when the server sandbox disables the mini-map; installs still on the old HOME default are auto-migrated to / on first game start
[*] [b]Floating toggle icon[/b]: an always-on-screen mini icon that toggles the mini-map on click — no hotkey needed; drag to reposition, position remembered, hover shows the current hotkey (can be disabled in settings)
[*] [b]Flexible sizing[/b]: four presets + free resize by dragging the mini-map edges, remembered automatically
[*] [b]Always-visible button bar[/b]: no more hover-expanding; gear button opens the unified settings window — two-column collapsible sections with expand/collapse all (no ESC menu needed)
[*] [b]Navigation targets[/b]: right-click the map to set a target — flag + edge direction arrow + distance, auto-clears on arrival; share to your faction with one click
[*] [b]Live zombie dots[/b] (off by default): real-time zombie positions with adjustable color / size / opacity / cap
[*] [b]Zombie heatmap[/b] toggle (off by default)
[*] [b]Animal icons[/b] (off by default): live nearby animals — separate wild/livestock toggles and 9 built-in species filters; the [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3765182411]third-party MOD compatibility pack[/url] adds supported species such as dogs and horses; map-symbol or colored item-icon style, adjustable size, opacity and color (colorblind-friendly 8-color palette)
[*] [b]Vehicle icons[/b] (off by default): steering-wheel markers for nearby vehicles; standard / heavy-duty / sports / emergency (lightbar) category filters, adjustable size, opacity and color
[*] [b]World map icons[/b]: zombie / animal / vehicle icons on the world map (M) too — four separate toggles; style, colors and filters follow your mini-map settings; a new paw button on the world map opens the settings window directly
[*] [b]Street names[/b]: on the corner mini-map too (vanilla only shows them on the world map)
[*] [b]Safehouse outlines[/b]: yours in green, others in red
[*] [b]Free look[/b]: drag to pan and stay, click once to snap back to the player; a recenter hint appears while panned away (like navigation apps)
[*] [b]Server sandbox controls[/b]: disable zombie dots / heatmap / animal / vehicle icons; limit zombie / animal / vehicle / safehouse-outline display distance; configure safehouse display, four livestock visibility modes and faction sharing — admin changes apply live
[*] [b]Singleplayer & multiplayer[/b]: works out of the box in SP; in MP the server enables the mod (PZ servers dictate the mod list — players can't sideload it), and admins stay in control via the sandbox options above — the mod only visualizes data the client already receives, no extra intel
[*] [b]Languages[/b]: Traditional Chinese / Simplified Chinese / English / Japanese
[/list]

[b]⚠️ Note for -debug users[/b]: HOME is a hidden engine render-debug key — pressing it switches the world render path (roughly half the FPS, snow visuals change), and it fires alongside anything bound to HOME. This mod now defaults to / (slash) and auto-migrates old installs; if your toggle is still on HOME, please rebind. In game, the mini-map shows an orange warning bar whenever a binding conflict or the legacy render path is detected, with instructions to recover.

[h2]🧩 Map MOD support[/h2]
Pair it with the [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]Minidoracat MiniMap - MOD Maps[/url] map pack addon: it ships
mini-map images and area outlines (with names, multi-language) for several map
MODs, [u]auto-detected[/u] — a map's image only shows when that map MOD is
enabled, so nothing is drawn for maps you don't have. Installing the map pack
also unlocks extra options (MOD map tiles toggle, outline toggle, outline color, outline opacity).
Map MOD authors can also ship their own support: render your map into a file
named [b]minidoracat_minimap.pyramid.zip[/b] and put it in [b]media/minimap/[/b] —
[u]no Lua required[/u]. This MOD auto-detects and overlays it (auto-aligned,
drawn above the base map).

[h2]🗺️ Built-in resource points (POI, 0.8.0+) + Zone layer API (0.7.0+)[/h2]
[b]Resource points ship with the mod[/b]: 499 built-in vanilla-map resource points across
14 categories (military, police, gun store, medical, pharmacy, fire, library, school,
grocery, gas, tools, outdoor, prison, storage — each with a distinct color). The
default "icon mode" draws a tinted silhouette icon at every point (no label clutter), with
an optional full-color icon style, with size and opacity sliders; an optional "Show resource blocks" adds translucent
blocks and names, and every category can be toggled in the "Resource point icons" section of
the unified settings window (each row shows its category icon; plus a quick toggle in
the gear panel). [u]Resource-point data is extracted directly from the official vanilla
map files[/u] (not hand-placed) — if a point looks wrong or misclassified, the official
data itself is wrong; it will be corrected once the game fixes its data and this mod
syncs with the update. This MOD also provides a zone-rendering framework:
`registerZoneProvider(ownerModId, providerFn, optionLabelKey)` lets addons supply rectangle
zone data while this MOD draws semi-transparent fills, outlines, centered names and icons on
both the mini-map and world map; passing optionLabelKey grants a dedicated per-provider
toggle. Pair it with the zone-display addon [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Minidoracat MiniMap Zones[/url]
(Mod ID: MinidoracatMiniMapZonesFor42) to additionally show server-defined zones (a
`zones.json` writable by external tools). Without the addon, this MOD's other features are
unaffected.

[h2]🔗 MOD series[/h2]
This is the series' [b]main MOD[/b] and works fully on its own; the addons below are optional (all require this MOD):
[list]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps[/url] — map pack addon: mini-map images + area outlines for map MODs
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3765182411]MOD Compatibility[/url] — third-party compatibility pack: adds species such as dogs and horses to the animal icons
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Zones[/url] — server custom-zone display (zones.json; requires this MOD 0.8.0+)
[/list]

[h2]📋 MOD info[/h2]
[list]
[*] [b]Mod ID:[/b] MinidoracatMiniMapFor42
[*] [b]Supported version:[/b] Build 42.20.0+
[*] Works in singleplayer / multiplayer (MP requires the server to enable the mod)
[/list]

[h2]💬 Feedback & community[/h2]
[url=https://discord.gg/Gur2V67]👉 Join the Discord server[/url]

[h2]📺 Follow the author[/h2]
[url=https://www.twitch.tv/minidoracat]🎬 Twitch channel[/url]

[b]#map #minimap #worldmap #Minidoracat[/b]

Workshop ID: 3763913359
Mod ID: MinidoracatMiniMapFor42
