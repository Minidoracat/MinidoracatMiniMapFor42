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
[*] [b]Image-based world map & corner mini-map[/b] — matches the in-game look; prefer vanilla? One toggle falls back to the vector style, everything else keeps working
[*] [b]Mini-map hotkey[/b]: / (slash, right of M) by default, rebindable; works even when the server sandbox disables the mini-map
[*] [b]Floating toggle icon[/b]: always-on-screen icon — left-click toggles the mini-map, right-click toggles ghost mode; drag to reposition, hover shows the current hotkeys (can be disabled)
[*] [b]Flexible sizing[/b]: four presets + free resize by dragging the mini-map edges, remembered automatically
[*] [b]Always-visible button bar[/b]: no more hover-expanding; gear button opens the unified settings window — collapsible two-column sections, no ESC menu needed
[*] [b]Navigation targets[/b]: right-click the map to set a target — flag + edge arrow + distance, auto-clears on arrival; share to your faction with one click
[*] [b]Live zombie dots[/b] (off by default): real-time zombie positions with adjustable color / size / opacity / cap
[*] [b]Zombie heatmap[/b] toggle (off by default)
[*] [b]Animal icons[/b] (off by default): live nearby animals — separate wild/livestock toggles, 9 built-in species filters (the [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3765182411]compatibility pack[/url] adds dogs, horses and more); map-symbol or item-icon style, adjustable size/opacity/color (colorblind-friendly palette)
[*] [b]Vehicle icons[/b] (off by default): steering-wheel markers; standard / heavy-duty / sports / emergency filters, adjustable size/opacity/color
[*] [b]World map icons[/b]: zombie / animal / vehicle icons on the world map (M) — four separate toggles; style and filters follow the mini-map; a paw button opens settings directly
[*] [b]Street names[/b]: on the corner mini-map too (vanilla only shows them on the world map)
[*] [b]Safehouse outlines[/b]: yours in green, others in red
[*] [b]Free look[/b]: drag to pan and stay, click once to snap back; a recenter hint appears while panned away
[*] [b]Player coordinates & one-click copy[/b]: current x, y, z at the bottom of the mini-map (toggleable); the XY button copies them and right-click copies any spot you point at — paste straight into /teleportto
[*] [b]Ghost mode (click-through)[/b]: clicks, wheel and right-clicks pass through to the game world while the map turns semi-transparent (opacity slider) — enlarge it into a permanent overlay that never blocks play; toggle via the ' hotkey, the floating icon's right-click, or settings
[*] [b]Server sandbox controls[/b]: disable dots/heatmap/animal/vehicle icons, limit display distances, configure safehouse display, livestock visibility and faction sharing — admin changes apply live
[*] [b]Singleplayer & multiplayer[/b]: works out of the box in SP; in MP the server enables the mod and admins stay in control via the sandbox options — it only visualizes data the client already receives, no extra intel
[*] [b]Languages[/b]: Traditional Chinese / Simplified Chinese / English / Japanese
[/list]

[b]⚠️ -debug users[/b]: HOME is a hidden engine render-debug key (switches the world render path — half the FPS, snow visuals change). This mod defaults to / and auto-migrates old HOME installs; an in-game orange warning bar flags binding conflicts or the legacy render path with recovery instructions.

[h2]🧩 Map MOD support[/h2]
Pair it with the [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]Minidoracat MiniMap - MOD Maps[/url] map pack addon: mini-map images and named area outlines for several map MODs, [u]auto-detected[/u] — a map's image only shows when that map MOD is enabled. The pack also unlocks extra options (tiles toggle, outline toggle/color/opacity).
Map MOD authors can ship their own support: render your map into [b]minidoracat_minimap.pyramid.zip[/b] under [b]media/minimap/[/b] — [u]no Lua required[/u]; this MOD auto-detects and overlays it above the base map.

[h2]🗺️ Built-in resource points (POI, 0.8.0+) + Zone layer API (0.7.0+)[/h2]
[b]Resource points ship with the mod[/b]: 636 built-in vanilla-map resource points across 14 categories (military, police, gun store, medical, pharmacy, fire, library, school, grocery, gas, tools, outdoor, prison, storage — each with a distinct color). Default "icon mode" draws tinted silhouette icons (full-color style optional, size/opacity sliders); optional "resource blocks" adds translucent blocks and names, with per-category toggles in the unified settings window. [u]Data is extracted directly from the official vanilla map files[/u] — misplaced points mean the official data is wrong and will sync once the game fixes it. A zone-rendering framework is also provided: `registerZoneProvider(ownerModId, providerFn, optionLabelKey)` lets addons supply rectangle zones while this MOD draws fills, outlines, names and icons on both maps (optionLabelKey grants a per-provider toggle). Pair with [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Minidoracat MiniMap Zones[/url] (MinidoracatMiniMapZonesFor42) for server-defined zones (`zones.json`). Without addons, everything else is unaffected.

[h2]🔗 MOD series[/h2]
This is the series' [b]main MOD[/b] and works fully on its own; the addons below are optional (all require this MOD):
[list]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps[/url] — map pack addon: mini-map images + area outlines for map MODs
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3765182411]MOD Compatibility[/url] — adds species such as dogs and horses to the animal icons
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
