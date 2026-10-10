<!-- Steam 討論區貼文稿源（English）；簡介只放摘要，詳細內容以本串為準 -->
<!-- 討論串網址：https://steamcommunity.com/workshop/filedetails/discussion/3763913359/586187095760051259/ -->
<!-- 標題：📖 MiniMap Guide: Features, Navigation & Road Data -->

[b]繁體中文版：[/b][url=https://steamcommunity.com/workshop/filedetails/discussion/3763913359/569297034317714443/]小地圖完整說明：功能、導航與道路資料[/url]

[h2]🚀 Quick start[/h2]
Requires Build 42.21.0+ and [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701]Minidoracat UI Library for B42[/url]; in multiplayer the server must enable it. Keep series mods updated; restart after updating. The gear's Map Display Settings window needs the updated UI Library; with an older one the gear only shows an update notice, and every setting is still in ESC → Options → MOD. UI languages: Traditional/Simplified Chinese, English, Japanese, Korean, Russian, Spanish, Portuguese, Turkish, French, Polish, German (please report any translation issues).
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
[*] [b]Two resource versions[/b]: "Mini-map list" is the curated list (one main use per building; covers the vanilla map and the map mods in a map pack, and follows a map mod that replaces a vanilla town). "Room data" reads room names while you play: a building counts for a category if any of its rooms does, can count for several, and every map mod is covered, so it marks more places (a school nurse's office counts as medical). Pick the mini-map list for each town's main facilities; pick room data for map mods outside the map pack, or to see every building that has such rooms. Switch at the top of the Resource points category; servers can set what players who never chose see with the sandbox option "Default resource point version", or lock everyone to it with "Players only see the default version". Room-data blocks always cover the whole building, and hovering an icon lists all of the building's categories.
[*] Categories come from room loot types (actual supplies), not zoning colors.
[*] Basement facilities show "↓" on the icon and "(basement)" in search and hover names; their use may differ from the building above.
[*] [b]Legend & hover names[/b]: a POI legend sits under the world-map legend (S hides both); hover an icon (gamepad: crosshair) to see its name.
[/list]

[h3]🅿️ Parking lots[/h3]
[list]
[*] Both maps mark parking lots with a blue area and a P icon: zoom in to see each row of stalls, zoom out to see only the P; one P per lot. Hover the P to see "Parking lot".
[*] [b]How lots are found[/b]: from the map's vehicle spawn spots (where the game places parked cars). Areas with painted parking lines or room for 6 or more cars are marked as parking lots; single spots and home driveways are not. On the vanilla map, street-side parking and spots on grass are left out too. This is automatic, so a few places may be wrong or missing.
[*] 573 lots on the vanilla map; with [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps[/url], the map mods it covers get them too (map mods keep street-side parking, and a big lot may show several P icons).
[*] On by default; turn it off in the "Parking lot" settings category or on the ESC options page. Icon size, opacity and display distance follow the resource point settings, including the server's resource point display distance.
[/list]

[h3]🔍 Search & trip window[/h3]
[list]
[*] Open with the toolbar magnifier, right-click "Search map...", or [b];[/b].
[*] Type coordinates (e.g. 12895,3499), a street name (original or translated), one of 20 facility categories, or "parking lot" for the nearest lots; sorted by distance.
[*] Show a result on the map, navigate to it or add it to your trip. Right-click results or trip stops for more actions.
[*] A "MOD map: name" tag only marks a confirmed source — not an error or a driving certification.
[/list]

[h3]🧭 Multi-target navigation[/h3]
[list]
[*] Up to 16 targets: add to the end, insert before a stop or "Go here first"; reorder, remove/undo, skip and preview the remaining route.
[*] New trips continue automatically; step mode or stopover targets wait for you. Existing trips stay step-by-step. In a vehicle, stop first. For a target on the road, stopping in the lane beside it counts as arrived; for an off-road target, you are told to walk the rest.
[*] After the last stop, the numbered stop markers disappear from the maps (the trip page still lists the results); to keep them, turn on "Keep finished trip on map" in the "Players & navigation" category of Map Display Settings. Adding a stop or setting a navigation target after a trip has finished starts a new trip numbered from 1, no clearing needed.
[*] Routes follow roads, preferring paved ones, and replan when you go off course.
[*] In MP you can share your current stop with your faction; servers can disable this. To hide targets others share with you, turn off "Show faction-shared targets" in "Players & navigation" (received shares are kept).
[*] Hands-free driving: [url=https://steamcommunity.com/workshop/filedetails/discussion/3792675881/586187095760051144/]AutoDrive Guide[/url].
[/list]

[h3]🏠 Home & favorites[/h3]
[list]
[*] Right-click the map: "Set as home" or "Add to favorites…" (named, unlimited).
[*] "Go home" replaces the trip with home and starts navigating (house button, right-click menu or trip page).
[*] An empty search box lists favorites to rename, remove or set as home. Saved per character; not inherited after death.
[*] To hide home and favorite icons on the maps, turn off "Show home & favorites" in "Players & navigation"; Go Home, the favorites list and the right-click menu still work.
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
[*] [b]Zombie dots[/b] (off by default): live positions in loaded areas; color, size, opacity and cap adjustable; vanilla heatmap toggle ("Show zombie heatmap").
[*] [b]Animal icons[/b] (off by default): wild/livestock toggles and species filters; MOD Compatibility adds dogs, horses and more.
[*] [b]Vehicle icons[/b] (off by default): standard / heavy / performance / emergency filters. Two icon styles, colorblind-friendly palette.
[*] [b]Also show on the world map[/b]: the zombie, animal (wild/livestock) and vehicle categories each have this toggle for the world map (M); style, colors and filters are shared with the mini-map.
[*] [b]Street names & safehouses[/b]: street names on the mini-map (hidden when zoomed far out); safehouse outline/icon/name toggles; custom names add the owner.
[*] [b]Chunk grid[/b] (off by default, in "Base map & text"): marks each 8x8-tile chunk and your chunk's number and range.
[*] [b]Sizes[/b]: icon size sliders for resource points, zombies, animals, vehicles, safehouses and custom zones, plus "Marker size (home, favorites, nav, search)" (also other mods' markers that have no layer yet) and "Map text size" (50–300%). Game-drawn street/place names don't scale. Search "size" in the settings window to find them all.
[*] [b]Display distance[/b]: the zombie, animal, vehicle, resource point and safehouse categories each have one, shown as "your value / server cap"; the lower applies, 0 = no limit.
[*] [b]Remote Symbols[/b] (MP only): the "Remote Symbols" category hides every map symbol other players share with you, or only certain authors (the same list as "Hide Author's Symbols" in the vanilla Sharing panel, stored on the server); right-click someone's symbol on the world map → "Hide X's map symbols". "Only faction and safehouse members' symbols" keeps only shares from your faction and safehouse; "Show all" brings everything back. With more than 20 authors, "Manage authors..." opens a searchable list.
[/list]

[h2]⚙️ Settings[/h2]

[h3]🎛️ Map Display Settings (gear)[/h3]
[list]
[*] [b]Open[/b]: the gear on the mini-map, or the paw-print button in the world map (M) button row. Changes apply and save instantly.
[*] [b]Four groups[/b] in the side list: "Map layers" (Base map & text, Players & navigation, Remote Symbols (MP only), Resource points, Parking lot, Zombies, Animals, Vehicles, Safehouses), "Window & controls" (Mini-map window, Performance notes), "Add-ons" and "Admin" (only when the server allows Tactical view and you have the permission). Each category has an icon; categories with a master switch toggle right in the list. The search box finds settings across categories.
[*] [b]Live previews[/b] at the top of the zombie, animal, vehicle, resource point, safehouse, players & navigation and custom zone categories show size, color, opacity, style and name changes the way the map draws them, even with nothing nearby.
[*] [b]Filter chips[/b]: resource point categories, animal species and vehicle categories are clickable chips, with icons colored as on the map.
[*] [b]Tooltips & reset[/b]: every toggle has the same help text as the ESC page (hover it). "Reset this category" restores this mod's defaults only; vanilla map-engine options stay. "Mini-map window" has "Reset to default size" to clear edge-drag resizing.
[*] [b]Add-on categories[/b]: Custom zones (Zones), Mod maps (MOD Maps) and series mods such as Vehicle Manager, Economy and AutoDrive each get one category, in a fixed order; an add-on shows its category once it is updated. Add-on map markers can come in layers, each with its own on/off, size and separate mini-map / world-map name toggles.
[*] [b]Gamepad & keyboard[/b]: open it with the gamepad from the mini-map gear, then the D-pad moves between search, categories and settings, A toggles, B closes back to the mini-map. Keyboard: Tab and arrow keys; arrows don't move your character while a setting has focus.
[*] [b]Layout[/b]: opened from the mini-map it lines up with it (opening downward when the mini-map is in the top half) and stays clear of the hotbar, scrolling when space is short. Large screens (900 px tall or more, game font not enlarged) get bigger text; when two columns don't fit (e.g. split screen) it shows one page at a time with "Back to categories".
[*] [b]Performance notes[/b]: the cost of each layer and what to do about it.
[*] [b]ESC → Options → MOD[/b]: the mini-map page follows the same categories with titles (Base map & text, Players & navigation, Resource points, Zombies, Animals, Vehicles, Safehouses, Mini-map window, Advanced) and holds every setting; both stay in sync.
[/list]

[h3]🛡️ Server settings (sandbox)[/h3]
[list]
[*] Pages "Minidoracat Mini-map - General", "Zombies, Animals & Vehicles", "Resource Points & Custom Zones", "Safehouses" and "Export": disable zombie dots, heatmap, animal and vehicle icons; cap display distances; four livestock-visibility levels; safehouse display scope; faction sharing toggle. Changes apply live.
[*] [b]Scan intervals[/b]: "Zombie dot scan interval" and "Vehicle and animal icon scan interval" (seconds) on the "Minidoracat Mini-map - Zombies, Animals & Vehicles" page. 0 (default) = real time; N = refresh only every N seconds, scanned around the player, so panning or zooming leaves no gaps. Admins in Tactical view always see real time; scanning runs on each client, so server load is unchanged.
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

[b]Q: The gear only says "The settings window needs a newer Minidoracat UI Framework"?[/b]
A: Your Minidoracat UI Library is outdated. Update it and restart; until then every setting is in ESC → Options → MOD and the mini-map works as usual.

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
