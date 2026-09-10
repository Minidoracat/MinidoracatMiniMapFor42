[h1]🗺️ Minidoracat MiniMap for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]⚠️ Required dependency (since 0.20.0)[/h2]
Since 0.20.0 this mod requires [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701][b]Minidoracat UI Library for B42[/b][/url] (the shared UI library). Please subscribe to it as well — see Required Items on this page. Updating this mod without subscribing to the library will stop it from loading.

[hr][/hr]

[h2]✨ What is this[/h2]
Overlays "map images rendered from the actual in-game view" onto the B42 world map and corner mini-map, replacing the vanilla vector-line style. Built on the engine's native ImagePyramid: multi-level LOD for smooth zooming, low VRAM, and what-you-see-is-what-you-get.

[h2]🧰 Main features[/h2]
[list]
[*] [b]Image-based world map & mini-map[/b] — matches the in-game view; switch back to vanilla vector style anytime
[*] [b]Navigation target + road-following route[/b]: right-click to set a target — a route is computed along actual roads (auto-replans when you stray; deep-wilderness targets route to the nearest road), with flag + edge arrow + distance, auto-clears on arrival; share to your faction and teammates get the route too
[*] [b]Map search[/b]: magnifier button or right-click "Search map…" — coordinates, street names ([u]English and translated names both work[/u]) or facility categories (pharmacy, gun store etc. across the 20 categories), sorted by distance; jump to the world map (gold pulsing marker) or set as navigation target directly. Streets whose source can be confirmed are tagged "Mod map: <map name>" — it only tells you which map the street comes from, it does not mean anything is wrong
[*] [b]Mini-map hotkey + floating icon[/b]: default / (rebindable), works even when the sandbox disables the mini-map; the always-on icon toggles the map (left-click) and ghost mode (right-click), drag to reposition
[*] [b]Free sizing[/b]: four presets + edge-drag resizing with memory; the button bar stays put — no hover-expanding
[*] [b]Live zombie dots[/b] (off by default): real-time zombie positions with adjustable color / size / opacity / cap; vanilla heatmap toggle included
[*] [b]Animal & vehicle icons[/b] (off by default): separate wild/livestock toggles, species and vehicle-category filters (the compatibility pack adds dogs, horses and more); two icon styles, colorblind-friendly palette
[*] [b]World-map icons[/b]: the same zombie/animal/vehicle icons on the world map (M), four independent toggles
[*] [b]Street names + safehouses[/b]: street names on the corner mini-map (vanilla never had them); safehouse outline / icon / name toggles, yours green, faction cyan, others red
[*] [b]Player coordinates + one-click copy[/b]: x, y, z at the bottom of both maps; the toolbar copy icon copies your position, while right-click copies any pointed spot — paste straight into /teleportto
[*] [b]Ghost mode[/b]: clicks and wheel pass through to the game while the map turns semi-transparent — enlarge it into a permanent overlay that never blocks play; hotkey '
[*] [b]Free look[/b]: drag to inspect and stay there, click once to snap back to the player
[*] [b]Map Display Settings[/b] (gear button): category navigation on the left, the current inspector on the right, plus cross-category search; split-screen and large fonts fall back to one pane automatically. Every change applies and saves instantly — no ESC menu needed. The whole UI set uses the family rounded dark skin; built-in Performance notes
[*] [b]Server sandbox controls[/b]: disable individual icons, cap display distances, four livestock-visibility levels, faction-sharing toggle — changes apply live
[*] [b]Singleplayer & multiplayer[/b]: only visualizes data the client already receives — no extra intel; Traditional/Simplified Chinese, English, Japanese
[/list]

[b]⚠️ -debug users[/b]: HOME is a hidden engine render-debug key (halves FPS). This mod defaults to / and auto-migrates old bindings; a conflict shows an orange warning bar.

[h2]🧩 Map mod support[/h2]
Pair with the [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps pack[/url]: mini-map images + boundary outlines for many map mods, auto-detected — shown only when the matching map mod is enabled. From 42.20.4-0.27.0 use map pack 42.20.4-0.9.0 or newer: update both and restart the game.
Map mod authors can ship their own support: render a [b]minidoracat_minimap.pyramid.zip[/b] into [b]media/minimap/[/b] — [u]no Lua needed[/u].

[h2]🗺️ Built-in POIs + zone layer API[/h2]
1669 points of interest across 20 categories on the vanilla map (military/medical/commercial/industrial etc., each color-coded): tinted-silhouette icons (full-color optional) or translucent blocks, per-category toggles in the settings window. Positions come straight from official map files; categories are derived from official room [u]loot types[/u] — they may disagree with the map's zoning colors (residential/commercial legend), the actual loot is what counts.
Basement facilities (B42 basements — a bar under a house, underground armories) get a "↓" corner mark on the icon and a "(basement)" suffix in search results — the building above ground may be something else.
A `registerZoneProvider` zone-rendering framework is also included; with the [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Zones addon[/url] it displays server-defined zones (zones.json), with a dedicated display distance (sandbox + player slider).

[h2]🔗 Mod series[/h2]
This is the [b]main mod[/b] — fully functional on its own; addons are optional:
[list]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps[/url] — images + outlines for map mods
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3765182411]MOD Compatibility[/url] — adds dogs, horses and more to animal icons
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Zones[/url] — server-defined zone display
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3792675881]AutoDrive[/url] — GPS navigation, driver HUD and road-network autodrive
[/list]

[h2]📋 Mod info[/h2]
[list]
[*] [b]Mod ID:[/b] MinidoracatMiniMapFor42
[*] [b]Supported version:[/b] Build 42.20.1+
[*] Singleplayer / multiplayer (server must enable the mod)
[/list]

[h2]💬 Feedback & community[/h2]
[url=https://discord.gg/Gur2V67]👉 Join the Discord server[/url]

[h2]☕ Support the author[/h2]
The mod is free and always will be. If you enjoy it, consider buying me a coffee - tips go straight into servers and mod development.
[url=https://ko-fi.com/minidoracat][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_kofi.png[/img][/url]

[b]#map #minimap #worldmap #Minidoracat[/b]

Workshop ID: 3763913359
Mod ID: MinidoracatMiniMapFor42
