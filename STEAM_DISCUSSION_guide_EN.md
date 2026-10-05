<!-- Steam 討論區貼文稿源（English）；簡介只放摘要，詳細內容以本串為準 -->
<!-- 討論串網址：https://steamcommunity.com/workshop/filedetails/discussion/3763913359/586187095760051259/ -->
<!-- 標題：📖 MiniMap Guide: Features, Navigation & Road Data -->

[b]繁體中文版：[/b][url=https://steamcommunity.com/workshop/filedetails/discussion/3763913359/569297034317714443/]小地圖完整說明：功能、導航與道路資料[/url]

[h2]🚀 Quick start[/h2]
Requires Build 42.21.0+ and [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701]Minidoracat UI Library for B42[/url]; in multiplayer the server must enable it. Keep series mods updated; restart after updating. UI languages: Traditional/Simplified Chinese, English, Japanese.
[olist]
[*] Press [b]/[/b] to toggle the mini-map (rebind: Options → Key Bindings → [MinidoracatMiniMap]). Or use the Minimap button in the family toolbar (right edge of the screen, left of the moodles): left-click toggles the mini-map, right-click ghost mode.
[*] Press [b]M[/b] for the world map.
[*] Press [b];[/b] for the search / trip window.
[*] Click the gear on the mini-map for Map Display Settings.
[/olist]

[h2]✨ Features in detail[/h2]

[h3]🗺️ Map imagery[/h3]
[list]
[*] Buildings, vegetation and ground textures become full-color top-down images on both maps.
[*] The "Image-based map" toggle restores the vanilla vector map; everything else keeps working.
[*] The optional MOD Maps pack adds rendered imagery and outlines for supported mod maps.
[*] Images are pre-rendered; building and tree cutting don't show.
[/list]

[h3]📍 Built-in POIs[/h3]
[list]
[*] 1669 vanilla POIs in 20 color-coded categories, as tinted silhouettes, full-color icons or translucent blocks, with per-category toggles.
[*] Categories come from room loot types (actual supplies), not zoning colors.
[*] Basement facilities show "↓" on the icon and "(basement)" in search and hover names; their use may differ from the building above.
[*] [b]Legend & hover names[/b]: a POI legend sits under the world-map legend (S hides both); hover an icon (gamepad: crosshair) to see its name.
[/list]

[h3]🔍 Search & trip window[/h3]
[list]
[*] Open with the toolbar magnifier, right-click "Search map...", or [b];[/b].
[*] Type coordinates (e.g. 12895,3499), a street name (original or translated) or one of 20 facility categories, sorted by distance.
[*] Show a result on the map, navigate to it or add it to your trip. Right-click results or trip stops for more actions.
[*] A "MOD map: name" tag only marks a confirmed source — not an error or a driving certification.
[/list]

[h3]🧭 Multi-target navigation[/h3]
[list]
[*] Up to 16 targets: add to the end, insert before a stop or "Go here first"; reorder, remove/undo, skip and preview the remaining route.
[*] New trips continue automatically; step mode or stopover targets wait for you. Existing trips stay step-by-step. In a vehicle, stop first. For a target on the road, stopping in the lane beside it counts as arrived; for an off-road target, you are told to walk the rest.
[*] After the last stop, the numbered stop markers disappear from the maps (the trip page still lists the results); to keep them, turn on "Keep finished trip on map" under Layers in Map Display Settings. Adding a stop or setting a navigation target after a trip has finished starts a new trip numbered from 1, no clearing needed.
[*] Routes follow roads, preferring paved ones, and replan when you go off course.
[*] In MP you can share your current stop with your faction; servers can disable this.
[*] Hands-free driving: [url=https://steamcommunity.com/workshop/filedetails/discussion/3792675881/586187095760051144/]AutoDrive Guide[/url].
[/list]

[h3]🏠 Home & favorites[/h3]
[list]
[*] Right-click the map: "Set as home" or "Add to favorites…" (named, unlimited).
[*] "Go home" replaces the trip with home and starts navigating (house button, right-click menu or trip page).
[*] An empty search box lists favorites to rename, remove or set as home. Saved per character; not inherited after death.
[/list]

[h3]🖱️ Mini-map controls[/h3]
[list]
[*] [b]Toggle button & hotkey[/b]: / works even if the sandbox disables the mini-map. The Minimap button lives in the family toolbar: collapse the toolbar (press [b].[/b] to open it) or hold any button to drag the whole strip; hide the button with "Show mini-map toggle button". With an older Minidoracat UI Library it stays a draggable floating icon.
[*] [b]Size[/b]: four presets, or drag an edge/corner to resize freely.
[*] [b]Ghost mode[/b] (hotkey [b]'[/b]): clicks and wheel pass through to the game; the map turns semi-transparent with an amber border.
[*] [b]Free look[/b]: drag to inspect; click once to snap back to the player.
[*] [b]Coordinates[/b]: x, y, z under both maps; the copy icon in the mini-map's button row copies yours, right-click "Copy coordinates" copies any spot.
[/list]

[h3]👁️ Icons & display[/h3]
[list]
[*] [b]Zombie dots[/b] (off by default): live positions in loaded areas; color, size, opacity and cap adjustable; vanilla heatmap toggle.
[*] [b]Animal icons[/b] (off by default): wild/livestock toggles and species filters; MOD Compatibility adds dogs, horses and more.
[*] [b]Vehicle icons[/b] (off by default): standard / heavy / performance / emergency filters. Two icon styles, colorblind-friendly palette.
[*] [b]World map (M)[/b]: the same zombie/animal/vehicle icons, four toggles.
[*] [b]Street names & safehouses[/b]: street names on the mini-map (hidden when zoomed far out); safehouse outline/icon/name toggles; custom names add the owner.
[*] [b]Chunk grid[/b] (off by default): marks each 8x8-tile chunk and your chunk's number and range.
[*] [b]Sizes[/b]: icon size sliders per type, plus "Marker size" (home, nav, pings, other mods' markers) and "Map text size" (50–300%). Game-drawn street/place names don't scale.
[*] [b]Map Display Settings[/b] (gear): searchable categories; saves instantly; per-feature performance notes.
[/list]

[h3]🛡️ Server settings (sandbox)[/h3]
[list]
[*] Disable zombie dots, heatmap, animal and vehicle icons; cap display distances; four livestock-visibility levels; safehouse display scope; faction sharing toggle. Changes apply live.
[*] Players can only tighten distances. Only data the client already receives is drawn.
[*] Custom server zones: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Zones[/url] (zones.json), with its own display distance.
[/list]

[h2]🧩 Mod maps & road data[/h2]
[b]Street names, street search and navigation need a native streets.xml from the map author. Without it the image still shows, but that area has no street names, search or navigation (not a missing translation).[/b]
[list]
[*] Roads must match the real surface, or routes fail, detour or go off-road.
[*] Overlapping maps follow map priority (in MP, the server Map= order); lower-priority streets can drop out, so neither original nor translated names are found.
[*] Which maps have road data: [url=https://steamcommunity.com/workshop/filedetails/discussion/3763914102/586187095760050601/]MOD Maps supported map list & requests[/url].
[/list]

[h3]For map authors[/h3]
[b]Imagery[/b] (no Lua): render [b]minidoracat_minimap.pyramid.zip[/b] into your mod's [b]media/minimap/[/b]; it mounts automatically.
[b]Roads[/b]: ship a correct native streets.xml:
[list]
[*] Path: media/maps/<map folder>/streets.xml in your mod's active common or version folder (the real map folder, not the Workshop title).
[*] Current street format; polylines on the road centre with 2+ valid points and a valid width, following real bends and junctions; connect junctions and map seams.
[*] worldmap.xml and images don't replace streets.xml. Restart after edits (no hot-reload).
[/list]
MiniMap doesn't auto-correct roads; it only fixes a few vanilla ones.

[h2]❓ FAQ[/h2]
[b]Q: The mod won't load / a dependency is missing?[/b]
A: Subscribe to and enable Minidoracat UI Library for B42, then restart.

[b]Q: No street names or navigation in a mod map area?[/b]
A: Usually no author road data, or a higher-priority map covers the area. See "Mod maps & road data".

[b]Q: Will it lower my FPS?[/b]
A: Barely at normal zoom: ~0.4 ms/frame with all icons on vs no mod (A/B test, B42.21.0). Far zoom-out with POIs costs more. If it lags: fewer POI categories, keep "UI Offscreen Rendering" on, lower "UI Rendering FPS", avoid -debug.

[h2]📝 Reporting issues[/h2]
[list]
[*] [b]General[/b]: [url=https://github.com/Minidoracat/MinidoracatMiniMapFor42/issues]GitHub Issues[/url] — include versions, SP/MP, steps and log excerpts (no credentials).
[*] [b]Road / route problems[/b] (off-road lines, missing roads, detours): [url=https://github.com/Minidoracat/MinidoracatAutoDriveFor42/issues/new?template=road-data.yml]road / route data report form[/url]. Attach [b]a screenshot with the route and coordinates + the coordinates as text[/b] and say what's wrong. [b]No Telemetry needed.[/b] Right-click the spot → "Copy coordinates".
[*] [b]Discord[/b]: https://discord.gg/Gur2V67
[/list]
