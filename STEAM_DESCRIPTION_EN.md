[h1]🗺️ Minidoracat MiniMap for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]⚠️ Required dependency (since 0.20.0)[/h2]
Since 0.20.0, [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701][b]Minidoracat UI Library for B42[/b][/url] is required. Subscribe via Required Items; this mod cannot load without it.

[hr][/hr]

[h2]✨ What is this[/h2]
Pre-rendered, full-color top-down maps made from map data and game textures bring the colors of rooftops, trees, roads and terrain to the B42 world map and corner mini-map. POI icons, street search and road navigation help you find supplies and plan routes.

[h2]Map imagery[/h2]
[list]
[*] [b]Rendered from map data and textures[/b] — buildings, vegetation and ground materials are combined into top-down images of each area's colors and landscape.
[*] [b]Imagery for supported mod maps[/b] — the MOD Maps pack supplies separately rendered images even when the original map has no terrain imagery. Support is limited to maps covered by the pack or supplied with compatible imagery by their authors.
[*] [b]Native multi-level zoom[/b] — the engine's ImagePyramid loads tiles at different resolutions as you zoom; switch back to the vanilla vector map anytime.
[/list]

The map background is pre-rendered: player construction, demolition and tree cutting do not update it live. Zombie, animal and vehicle icons update from data already available to the client.

[h2]🧰 Main features[/h2]
[list]
[*] [b]Multi-target navigation[/b]: up to 16 targets; append, insert or prioritize, reorder, remove/undo, skip and preview. New trips auto-continue; marked stopovers or step mode wait for you (existing trips stay step-by-step). Vehicles stop first. Road routes replan on deviation; faction sharing covers the current target only
[*] [b]Search / trip window[/b]: open with the magnifier or ; (rebindable), with collapse support. Search coordinates, [u]original/translated street names[/u] and 20 facility categories; show a result on the map or add it to the trip. "MOD map: name" identifies a confirmed source
[*] [b]Mini-map hotkey + floating icon[/b]: default / (rebindable), works even when the sandbox disables the mini-map; the always-on icon toggles the map (left-click) and ghost mode (right-click), drag to reposition
[*] [b]Free sizing[/b]: four presets + edge-drag resizing with memory; the button bar stays put — no hover-expanding
[*] [b]Live zombie dots[/b] (off by default): real-time zombie positions with adjustable color / size / opacity / cap; vanilla heatmap toggle included
[*] [b]Animal & vehicle icons[/b] (off by default): separate wild/livestock toggles, species and vehicle-category filters (the compatibility pack adds dogs, horses and more); two icon styles, colorblind-friendly palette
[*] [b]World-map icons[/b]: the same zombie/animal/vehicle icons on the world map (M), four independent toggles
[*] [b]Street names + safehouses[/b]: street names on the corner mini-map (vanilla never had them); safehouse outline / icon / name toggles, yours green, faction cyan, others red
[*] [b]Player coordinates + one-click copy[/b]: x, y, z at the bottom of both maps; the toolbar copy icon copies your position, while right-click copies any pointed spot — paste straight into /teleportto
[*] [b]Ghost mode[/b]: clicks and wheel pass through to the game while the map turns semi-transparent — enlarge it into a permanent overlay that never blocks play; hotkey '
[*] [b]Free look[/b]: drag to inspect and stay there, click once to snap back to the player
[*] [b]Map Display Settings[/b] (gear): left-side categories, right-side settings and cross-category search; split-screen/large fonts use one pane. Instant apply/save, no ESC; settings, search and mini-map share the rounded dark skin, with per-feature Performance notes and tips
[*] [b]Server sandbox controls[/b]: disable individual icons, cap display distances, four livestock-visibility levels, faction-sharing toggle — changes apply live
[*] [b]Singleplayer & multiplayer[/b]: only visualizes data the client already receives — no extra intel; Traditional/Simplified Chinese, English, Japanese
[/list]

[b]⚠️ -debug users[/b]: HOME is a hidden engine render-debug key (halves FPS). This mod defaults to / and auto-migrates old bindings; a conflict shows an orange warning bar.

[h2]🧩 Map mod support[/h2]
The optional [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps pack[/url] automatically shows imagery and boundaries for supported, enabled maps. Requires main mod 42.20.4-0.27.0+ and pack 42.20.4-0.9.0+; restart after updating. Overlaps follow map priority; streets may be excluded from search/navigation. [url=https://steamcommunity.com/workshop/filedetails/discussion/3763913359/569297034317714443/]Street data guide[/url].
Map mod authors can ship their own support: render a [b]minidoracat_minimap.pyramid.zip[/b] into [b]media/minimap/[/b] — [u]no Lua needed[/u].

[h2]🗺️ Built-in POIs + zone layer API[/h2]
1669 vanilla POIs in 20 color-coded categories (military/medical/commercial/industrial etc.). Tinted silhouette or full-color icons, or translucent blocks; per-category toggles. Positions come from official map files, categories from room [u]loot types[/u], not necessarily the map's zoning colors: actual supplies determine the category.
Basement facilities (B42 basements — a bar under a house, underground armories) get a "↓" corner mark on the icon and a "(basement)" suffix in search results — the building above ground may be something else.
A `registerZoneProvider` zone-rendering framework is also included; with the [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Zones addon[/url] it displays server-defined zones (zones.json), with a dedicated display distance (sandbox + player slider).

[h2]🔗 Mod series[/h2]
With the required library installed, the [b]main mod[/b] works without addons; choose them as needed:
[list]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps[/url] — images + outlines for map mods
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3765182411]MOD Compatibility[/url] — adds dogs, horses and more to animal icons
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Zones[/url] — server-defined zone display
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3792675881]AutoDrive[/url] — multi-target driving needs MiniMap 0.28.0+ and AutoDrive 0.8.0+; fully restart after updating
[/list]

[h2]📋 Mod info[/h2]
[list]
[*] [b]Mod ID:[/b] MinidoracatMiniMapFor42
[*] [b]Supported version:[/b] Build 42.20.1+
[*] Singleplayer / multiplayer (server must enable the mod)
[/list]

[h2]💬 Feedback & community[/h2]
[url=https://discord.gg/Gur2V67]👉 Join the Discord server[/url]

[url=https://github.com/Minidoracat/MinidoracatAutoDriveFor42/issues/new?template=road-data.yml][b]Road / route data report[/b][/url]: misplaced routes, gaps or detours — attach [b]a route screenshot showing coordinates + copyable coordinates as text[/b], and describe the problem. Endpoints, direction and map mod/version help; [b]no Telemetry required[/b]. Right-click the affected map point and choose Copy coordinates.

[h2]☕ Support the author[/h2]
The mod is free and always will be. If you enjoy it, consider buying me a coffee - tips go straight into servers and mod development.
[url=https://ko-fi.com/minidoracat][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_kofi.png[/img][/url]

[b]#map #minimap #worldmap #Minidoracat[/b]

Workshop ID: 3763913359
Mod ID: MinidoracatMiniMapFor42
