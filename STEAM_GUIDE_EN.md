<!-- 指南網址：https://steamcommunity.com/sharedfiles/filedetails/?id=3817841972 -->
<!-- Steam guide source (English): the full reference for this mod; the Workshop description only summarizes. Format and sync: pz-family-docs/release.md「完整說明：Steam 指南」 -->
<!-- 標題：📖 MiniMap Mod Guide: Features, Navigation & Road Data -->
<!-- 摘要：Illustrated guide to the Minidoracat MiniMap mod: map imagery, resource points, parking lots, search and multi-target navigation, home and favorites, mini-map controls and icons, Map Display Settings and server sandbox options, and road data for mod maps. -->
=== 🚀 Quick start
[b]繁體中文版：[/b][url=https://steamcommunity.com/sharedfiles/filedetails/?id=3817841920]小地圖 MOD 完整說明[/url]

The mod on Steam Workshop:
https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359
[list]
[*] [b]Requires[/b]: Build 42.21.0+ and [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701]Minidoracat UI Library for B42[/url].
[*] [b]Multiplayer[/b]: the server must enable it.
[*] [b]Updates[/b]: keep series mods updated to the latest version; fully restart the game after updating.
[*] [b]Older UI Library[/b]: the gear's Map Display Settings window needs the updated UI Library; with an older one the gear only shows an update notice, and every setting is still in ESC → Options → MOD.
[*] [b]UI languages[/b]: Traditional/Simplified Chinese, English, Japanese, Korean, Russian, Spanish, Portuguese, Turkish, French, Polish, German (please report any translation issues).
[/list]
[olist]
[*] Press [b]/[/b] to toggle the mini-map (rebind: Options → Key Bindings → [MinidoracatMiniMap]). Or use the Minimap button in the family toolbar (right edge of the screen, left of the moodles): left-click toggles the mini-map, right-click ghost mode.
[*] Press [b]M[/b] for the world map.
[*] Press [b];[/b] for the search / trip window: look up coordinates, street names or facilities, then set one as your navigation target or add it to your trip.
[*] Click the gear on the mini-map for Map Display Settings.
[/olist]
=== 🧰 Map imagery
{{img:04-worldmap-key-symbols.jpg}}
[list]
[*] [b]Full-color maps[/b]: buildings, vegetation and ground textures become full-color top-down images, used on both the world map and the corner mini-map, with tiered zoom levels.
[*] [b]Vanilla map[/b]: the "Image-based map" master toggle restores the vanilla vector map; icons and everything else keep working.
[*] [b]Mod maps[/b]: the optional MOD Maps pack adds rendered imagery and outlines for supported mod maps, even ones that ship no imagery of their own.
[*] [b]Pre-rendered[/b]: the images don't update live, so player building, demolition and tree cutting don't show.
[*] [b]Icons that update[/b]: zombie, animal and vehicle icons update from the data your client has already received.
[/list]
{{img:07-minimap-frame.jpg}}
=== 🧰 Built-in POIs
{{img:01-settings-poi.jpg}}
[list]
[*] [b]Count[/b]: 1669 vanilla POIs in 20 color-coded categories.
[*] [b]Styles[/b]: tinted silhouettes, full-color icons or translucent blocks.
[*] [b]Toggles[/b]: per category.
[*] [b]Basements[/b]: basement facilities show "↓" on the icon and "(basement)" in search and hover names; their use may differ from the building above.
[/list]
[h3]Two marking methods[/h3]
Both go by the room names inside buildings, which are also what decides the loot; neither follows the vanilla map's building colors. Locations come from the official map.
[table]
[tr][th]Method[/th][th]How it marks[/th][th]Maps covered[/th][th]Best for[/th][/tr]
[tr][td]By main use (default)[/td][td]Each building gets one main use, and small rooms tucked inside homes are left out, so only places worth a trip are marked[/td][td]The vanilla map and the map mods in a map pack; follows a map mod that replaces a vanilla town[/td][td]Each town's main facilities[/td][/tr]
[tr][td]By room[/td][td]Reads room names while you play; a building is marked if any one of its rooms is of that type and can be in several types, so more places are marked (a home bar in a house is marked as Food / Dining)[/td][td]Every map mod[/td][td]Map mods outside the map pack, or finding every room of a type[/td][/tr]
[/table]
[list]
[*] [b]By room blocks[/b]: always cover the whole building; hovering an icon lists every type the building belongs to.
[*] [b]Switch[/b]: "Marking method" at the top of the Resource points category.
[*] [b]Server default[/b]: the sandbox option "Default resource point marking" sets the method for players who never chose.
[*] [b]Server lock[/b]: "Players only use the default marking" locks everyone to it.
[/list]
[h3]Legend & hover names[/h3]
[list]
[*] [b]Legend[/b]: a POI legend sits under the vanilla legend in the top left of the world map (M), listing what each POI icon means for the categories you have on (S hides both).
[*] [b]Hover names[/b]: hover a POI icon on the mini-map or world map to see the facility name above it; basement facilities add "(basement)".
[*] [b]Custom zones[/b]: server custom zones show the zone name.
[*] [b]Gamepad[/b]: on the world map, aim with the crosshair in the middle of the screen.
[*] [b]Ghost mode[/b]: no hover names on the mini-map in ghost mode.
[/list]
=== 🧰 Parking lots
[list]
[*] [b]On the maps[/b]: both maps mark parking lots with a blue area and a P icon: zoom in to see each row of stalls, zoom out to see only the P; one P per lot.
[*] [b]Hover[/b]: hover the P to see "Parking lot".
[*] [b]Count[/b]: 573 lots on the vanilla map; with [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps[/url], the map mods it covers get them too (map mods keep street-side parking, and a big lot may show several P icons).
[*] [b]Toggle[/b]: on by default; turn it off in the "Parking lot" settings category or on the ESC options page.
[*] [b]Size and distance[/b]: icon size, opacity and display distance follow the resource point settings, including the server's resource point display distance.
[/list]
[h3]How lots are found[/h3]
[list]
[*] From the map's vehicle spawn spots (where the game places parked cars).
[*] Areas with painted parking lines or room for 6 or more cars are marked as parking lots.
[*] Single spots and home driveways are not. On the vanilla map, street-side parking and spots on grass are left out too.
[*] This is automatic, so a few places may be wrong or missing.
[/list]
=== 🧰 Search & trip window
{{img:05-search-street.jpg}}
[list]
[*] [b]Open[/b]: the magnifier in the mini-map or world map button row, right-click the map → "Search map...", or [b];[/b].
[*] [b]Type[/b]:
[list]
[*] coordinates (e.g. 12895,3499)
[*] a street name (original or translated)
[*] one of 20 facility categories
[*] "parking lot" for the nearest lots
[/list]
[*] [b]Order[/b]: sorted by distance.
[*] [b]Results[/b]: show a result on the map, navigate to it or add it to your trip. Right-click results or trip stops for more actions.
[*] [b]"MOD map: name" tag[/b]: a street result with this tag only marks a confirmed data source — not an error, and not an AutoDrive certification.
[/list]
{{img:11-search-basement.jpg}}
=== 🧰 Multi-target navigation
{{img:08-nav-route-worldmap.jpg}}
[h3]Trips[/h3]
{{img:03-nav-menu.jpg}}
[list]
[*] [b]Up to 16 targets[/b]: add to the end, insert before a stop or "Go here first".
[*] [b]Trip page[/b]: reorder, remove/undo, skip and preview the remaining route.
[*] [b]Continuing[/b]: new trips continue to the next stop automatically on arrival; switch to step mode, or mark single targets as stopovers, and they wait for you to continue. Existing trips stay step-by-step.
[*] [b]In a vehicle[/b]: the trip only continues once you've stopped.
[*] [b]Arriving[/b]: for a target on the road, stopping in the lane beside it counts as arrived (no need to cross to the other side of the centre line); for an off-road target, reaching the roadside tells you to walk the rest.
[*] [b]After the last stop[/b]: the numbered stop markers disappear from the maps (the trip page still lists the results); to keep them, turn on "Keep finished trip on map" in the "Players & navigation" category of Map Display Settings.
[*] [b]New trip[/b]: adding a stop or setting a navigation target after a trip has finished starts a new trip numbered from 1, no clearing needed.
[/list]
{{img:09-nav-route-minimap.jpg}}
[h3]Routes[/h3]
[list]
[*] [b]Roads[/b]: routes follow roads and slightly prefer paved ones when there is a reasonable alternative; places reachable only by gravel or dirt roads are still reachable.
[*] [b]Off course[/b]: routes replan automatically when you go off course.
[*] [b]Hands-free driving[/b]: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3817845953]AutoDrive Guide[/url].
[/list]
[h3]Sharing with your faction (MP)[/h3]
{{img:10-nav-route-shared.jpg}}
[list]
[*] [b]What[/b]: your current target (only the current stop is shared).
[*] [b]How[/b]: right-click the map → "Itinerary", or "Actions…" on the trip page of the search window (the keyboard and controller way).
[*] [b]Server[/b]: servers can disable this.
[*] [b]Hide others' targets[/b]: turn off "Show faction-shared targets" in "Players & navigation" (received shares are kept).
[/list]
=== 🧰 Home & favorites
[list]
[*] [b]Set[/b]: right-click the map → "Favorites": "Set as home" or "Add to favorites…".
[*] [b]Remove or rename[/b]: right-click a favorite's icon (or name) on the map → "Favorite: <name>": "Remove from favorites", "Rename…" or "Set as home"; removing asks first.
[*] [b]Favorites[/b]: named, unlimited.
[*] [b]New home[/b]: setting a new home keeps the old one as a favorite.
[*] [b]Go home[/b]: replaces the trip with a single stop home and starts navigating (the mini-map's house button, right-click → "Favorites", or the trip page).
[*] [b]Favorites list[/b]: an empty search box lists favorites; right-click one (or select it and press "Actions…") to rename, remove or set it as home.
[*] [b]Saved[/b]: kept on your PC per account (one set per server account in multiplayer, one per save in single player), so a new character still has them after death; to move them to another PC, copy the Zomboid/Lua/MinidoracatMiniMap/places folder.
[*] [b]Hide icons[/b]: turn off "Show home & favorites" in "Players & navigation"; Go Home, the favorites list and the right-click menu still work.
[/list]
=== 🧰 Mini-map controls
[list]
[*] [b]Hotkey[/b]: / works even if the sandbox disables the mini-map.
[*] [b]Toggle button[/b]:
[list]
[*] The Minimap button lives in the family toolbar: collapse the toolbar (press [b].[/b] to open it) or hold any button to drag the whole strip.
[*] Hide the button with "Show mini-map toggle button".
[*] With an older Minidoracat UI Library it stays a draggable floating icon.
[/list]
[*] [b]Size[/b]: four presets (Small, Medium, Large, Extra Large), or drag an edge/corner to resize freely; it's remembered automatically.
[*] [b]Ghost mode[/b] (hotkey [b]'[/b]): clicks and wheel pass through to the game; the map turns semi-transparent with an amber border, so you can make it big and keep it on screen without it getting in the way.
[*] [b]Free look[/b]: drag the map and it stays there; click once to snap back to the player.
[*] [b]Coordinates[/b]:
[list]
[*] x, y, z under both maps.
[*] The copy icon in the mini-map's button row copies yours.
[*] Right-click the map → "Copy coordinates" copies the spot you point at.
[*] You can paste them straight into /teleportto.
[/list]
[*] [b]Teleport Here[/b] (MP server staff only): right-click the mini-map → "Teleport Here" is the first item, same as on the world map; only roles that can use /teleportto (admin, moderator, GM, observer) see it.
[/list]
=== 🧰 Icons & display
[h3]Zombies, animals and vehicles[/h3]
[list]
[*] [b]Zombie dots[/b] (off by default): live positions in loaded areas; color, size, opacity and cap adjustable; vanilla heatmap toggle ("Show zombie heatmap").
[*] [b]Animal icons[/b] (off by default): wild/livestock toggles and species filters; MOD Compatibility adds dogs, horses and more.
[*] [b]Vehicle icons[/b] (off by default): standard / heavy / performance / emergency filters.
[*] [b]Styles[/b]: animal and vehicle icons both have two icon styles and a colorblind-friendly palette.
[*] [b]Mini-map or world map[/b]: every layer category has a "Show on" row with "Mini-map" and "World map" buttons to choose where it is drawn; the category switch turns both on or off. Zombies, animals and vehicles are off on the world map by default; style, colors and filters are shared with the mini-map.
[/list]
[h3]Street names, safehouses and chunk grid[/h3]
[list]
[*] [b]Street names[/b]: also on the corner mini-map (vanilla doesn't show them there; hidden when zoomed far out).
[*] [b]Safehouses[/b]: drawn on both the mini-map and the world map ("Show on" can keep just one); outline/icon/name toggles; yours in green, your faction's in cyan, others' in red.
[*] [b]Your own safehouses[/b]: always shown, however far away you are, regardless of the server's safehouse display distance; faction and other players' safehouses still follow it.
[*] [b]When zoomed out[/b]: other players' safehouses smaller than their icon on screen are drawn as an outline only, and ones down to a dot are skipped; yours are always shown in full.
[*] [b]Safehouse names[/b]: custom names add the owner's account in brackets (for safehouses managed by a safehouse mod, the real owner instead of the mod's service account; the "Own and faction" setting also judges factions by the real owner).
[*] [b]Safehouses split into pieces[/b]: when a safehouse mod builds one safehouse from several pieces (an L shape, say), it is drawn as one outline with a single name and icon.
[*] [b]Chunk grid[/b] (off by default, in "Base map & text"): alternating shading and grid lines mark each chunk (the 8x8-tile save unit); your chunk gets an amber frame with its number and coordinate range, and every cell is numbered when the mini-map is zoomed in. The text can be turned off separately and hides itself when zoomed out too far.
[/list]
[h3]Sizes and display distance[/h3]
[list]
[*] [b]Icon sizes[/b]: size sliders for resource points, zombies, animals, vehicles, safehouses and custom zones.
[*] [b]Marker size (home, favorites, nav, search)[/b]: home and favorites, the navigation flag and trip stops, search result pins, and other mods' markers that have no layer yet.
[*] [b]Map text size[/b] (50–300%): all text and legends this mod draws on the maps. Street names, place names and player names are drawn by the game and don't scale.
[*] [b]Find them all[/b]: search "size" in the settings window.
[*] [b]Display distance[/b]: the zombie, animal, vehicle, resource point and safehouse categories each have one, shown as "your value / server cap"; the lower applies, 0 = no limit.
[/list]
[h3]Remote Symbols (MP only)[/h3]
[list]
[*] [b]Hide[/b]: the "Remote Symbols" category hides every map symbol other players share with you, or only certain authors (the same list as "Hide Author's Symbols" in the vanilla Sharing panel, stored on the server).
[*] [b]Right-click[/b]: right-click someone's symbol on the world map → "Hide X's map symbols".
[*] [b]Only faction and safehouse members' symbols[/b]: keeps only shares from your faction and safehouse.
[*] [b]Show all[/b]: brings everything back.
[*] [b]Many authors[/b]: with more than 20 authors, "Manage authors..." opens a searchable list.
[/list]
=== ⚙️ Map Display Settings (gear)
{{img:02-settings-addons.jpg}}
[list]
[*] [b]Open[/b]: the gear on the mini-map, or the white cat paw button in the world map (M) button row.
[*] [b]MiniMap button on the world map[/b]: the MiniMap button (colorful stacked-map icon) in the world map button row opens this mod's small panel: map imagery, "Map layers" (hide or bring back everything this mod draws on the world map at once), and world-map toggles for each layer, home and favorites, and the navigation route; in multiplayer also faction-shared targets and "Only faction and safehouse members' symbols". Nothing is added to the vanilla gear options.
[*] [b]Saving[/b]: changes apply and save instantly; no need to press ESC.
[/list]
[h3]Categories[/h3]
[list]
[*] [b]Four groups[/b] in the side list:
[list]
[*] Map layers: Base map & text, Players & navigation, Remote Symbols (MP only), Resource points, Parking lot, Zombies, Animals, Vehicles, Safehouses
[*] Window & controls: Mini-map window, Performance notes
[*] Add-ons
[*] Admin: only when the server allows Tactical view and you have the permission
[/list]
[*] [b]Side list[/b]: each category has an icon; categories with a master switch toggle right in the list.
[*] [b]Search box[/b]: finds settings across categories.
[*] [b]Add-on categories[/b]: Custom zones (Zones), Mod maps (MOD Maps) and series mods such as Vehicle Manager, Economy and AutoDrive each get one category, in a fixed order; an add-on shows its category once it is updated.
[*] [b]Add-on map markers[/b]: can come in layers, each with its own on/off, "Show on" (mini-map / world map), size and separate mini-map / world-map name toggles.
[*] [b]Performance notes[/b]: the cost of each layer and what to do about it.
[/list]
[h3]Previews, filters and reset[/h3]
[list]
[*] [b]Live previews[/b]: at the top of the zombie, animal, vehicle, resource point, safehouse, players & navigation and custom zone categories; they show size, color, opacity, style and name changes the way the map draws them, even with nothing nearby.
[*] [b]Filter chips[/b]: resource point categories, animal species and vehicle categories are clickable chips, with icons colored as on the map.
[*] [b]Tooltips[/b]: every toggle has the same help text as the ESC page (hover it).
[*] [b]Reset this category[/b]: restores this mod's defaults only; vanilla map-engine options stay.
[*] [b]Reset to default size[/b]: in "Mini-map window", clears edge-drag resizing.
[/list]
[h3]Controls and layout[/h3]
[list]
[*] [b]Gamepad[/b]: open it from the mini-map gear, then the D-pad moves between search, categories and settings, A toggles, B closes back to the mini-map.
[*] [b]Keyboard[/b]: Tab and arrow keys; arrows don't move your character while a setting has focus.
[*] [b]Position[/b]: opened from the mini-map it lines up with it (opening downward when the mini-map is in the top half) and stays clear of the hotbar, scrolling when space is short.
[*] [b]Large screens[/b] (900 px tall or more, game font not enlarged): bigger text.
[*] [b]Narrow screens[/b] (e.g. split screen): when two columns don't fit it shows one page at a time with "Back to categories".
[/list]
[h3]ESC → Options → MOD[/h3]
[list]
[*] The mini-map page follows the same categories with titles (Base map & text, Players & navigation, Resource points, Zombies, Animals, Vehicles, Safehouses, Mini-map window, Advanced).
[*] It holds every setting; both stay in sync.
[/list]
=== ⚙️ Server settings (sandbox)
{{img:06-admin-sandbox-pages.jpg}}
[list]
[*] [b]Pages[/b]: "Minidoracat Mini-map - General", "Zombies, Animals & Vehicles", "Resource Points & Custom Zones", "Safehouses" and "Export".
[*] [b]Options[/b]:
[list]
[*] disable zombie dots, heatmap, animal and vehicle icons
[*] cap display distances
[*] four livestock-visibility levels
[*] safehouse display scope
[*] faction sharing toggle
[/list]
[*] [b]Live[/b]: changes apply live.
[*] [b]Display distance[/b]: players can only set their own display distance stricter than the server, not looser.
[*] [b]Data[/b]: this mod only draws data the client already receives; it gives no extra intel.
[*] [b]Custom server zones[/b]: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Zones[/url] (zones.json), with its own display distance.
[/list]
[h3]Scan intervals[/h3]
[list]
[*] [b]Where[/b]: "Zombie dot scan interval" and "Vehicle and animal icon scan interval" (seconds) on the "Minidoracat Mini-map - Zombies, Animals & Vehicles" page.
[*] [b]0 (default)[/b]: real time.
[*] [b]N[/b]: refresh only every N seconds, scanned around the player, so panning or zooming leaves no gaps.
[*] [b]Admins[/b]: admins in Tactical view always see real time.
[*] [b]Server load[/b]: scanning runs on each client, so server load is unchanged.
[/list]
=== ⚙️ For map authors
[h3]Imagery[/h3]
No Lua needed: render [b]minidoracat_minimap.pyramid.zip[/b] into your mod's [b]media/minimap/[/b]; it mounts automatically.
[h3]Roads[/h3]
Usually no MiniMap-specific code is needed; just ship a correct native streets.xml:
[list]
[*] [b]Path[/b]: media/maps/<map folder>/streets.xml in your mod's active common or version folder (the real map folder the world loads, not the Workshop title).
[*] [b]Format[/b]: the current game version's street format; every polyline needs at least two valid points and a valid width.
[*] [b]Drawing[/b]: draw polylines along the road centre, with coordinates, width, bends and junctions matching the real road; don't cut across grass, buildings or the inside of bends.
[*] [b]Connections[/b]: check that junctions and map seams connect; missing segments or breaks cause detours or no route.
[*] [b]No substitutes[/b]: map images and worldmap.xml don't replace streets.xml.
[*] [b]Restart after edits[/b]: restart the game after changing road files; navigation doesn't hot-reload.
[/list]
MiniMap doesn't detect the real road surface to correct coordinates; it only has built-in fixes for a few vanilla roads.
=== ⚠️ Mod maps & road data
[b]Street names, street search and navigation only work on maps whose author provides road data; having map images doesn't mean navigation or AutoDrive works.[/b]
[list]
[*] [b]Source[/b]: street names on the map, street search, navigation and the AutoDrive road network all come from the native streets.xml the map author ships in the mod.
[*] [b]Without it[/b]: the image still shows, but that area has no street names, search or navigation — it's not a missing translation in the map pack.
[*] [b]Accuracy[/b]: road coordinates, widths, bends and junctions must match the real surface; gaps, breaks or offsets can mean no route, detours or going off-road.
[*] [b]Overlapping maps[/b]: roads follow map priority (in MP, the server Map= order); streets in lower-priority areas can drop out, so neither original nor translated names are found.
[*] [b]Which maps have road data[/b]: which maps have author road data and which had roads added by the map pack: [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3817840392]MOD Maps supported map list[/url].
[/list]
=== ❓ FAQ
[h3]The mod won't load / a dependency is missing?[/h3]
[list]
[*] Subscribe to and enable [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701]Minidoracat UI Library[/url], then restart the game.
[/list]
[h3]The gear only says "The settings window needs a newer Minidoracat UI Framework"?[/h3]
[list]
[*] Your Minidoracat UI Library is outdated. Update it and restart.
[*] Until then every setting is in ESC → Options → MOD and the mini-map works as usual.
[/list]
[h3]No street names or navigation in a mod map area?[/h3]
[list]
[*] Usually the map's author didn't include road data, or a higher-priority map covers that area.
[*] See "Mod maps & road data" and the MOD Maps supported map list.
[/list]
[h3]Will it lower my FPS?[/h3]
[list]
[*] [b]Barely at normal zoom[/b]: in September 2026 on B42.21.0 we ran an A/B test with the game's built-in GameProfiler (3 runs each). With the mini-map open and resource points plus zombie/animal/vehicle icons all on, each frame took only about 0.4 ms more on average than with no mod and no mini-map (about 2% of a frame at 60 fps), and FPS stayed at the same level as without the mod (test machine: Ryzen 9 9950X3D; the default settings turn on fewer icons, so the cost is lower).
[*] [b]Far zoom-out costs more[/b]: with a whole city or even the whole map on screen and resource points on, every redraw handles over a thousand resource points. The 2026-09-30 update cut the cost at maximum zoom-out to about 40% of what it was, but it's still heavier than normal zoom.
[*] [b]Higher FPS to begin with[/b]: the same few extra milliseconds look like a bigger drop.
[/list]
[h3]What if it lags?[/h3]
[list]
[*] Stay at normal zoom most of the time and zoom out only when you need to see far.
[*] "Map Display Settings → Performance notes" lists each layer's cost: turn on only the POI categories you need, and lower the zombie dot cap or turn the dots off first.
[*] Keep the game's "UI Offscreen Rendering" setting on (on by default); turned off, the UI redraws every frame, and so does the mini-map.
[*] Lower the game's "UI Rendering FPS" (default 60, e.g. to 30): the mini-map redraws fewer times per second, at the cost of less smooth UI updates.
[*] Don't launch with -debug for normal play: Lua runs slower in debug mode, and the mini-map measured about 15–30% more time.
[/list]
=== 💬 Reporting issues
[list]
[*] [b]General[/b]: [url=https://github.com/Minidoracat/MinidoracatMiniMapFor42/issues]GitHub Issues[/url]. Include
[list]
[*] game / mod versions
[*] SP or MP
[*] steps to reproduce
[*] relevant log excerpts (remove credentials and private server info before sharing)
[/list]
[*] [b]Road / route problems[/b] (off-road lines, missing roads, detours): [url=https://github.com/Minidoracat/MinidoracatAutoDriveFor42/issues/new?template=road-data.yml]road / route data report form[/url]. Attach
[list]
[*] [b]a screenshot with the route and coordinates + the coordinates as text[/b] (right-click the spot → "Copy coordinates")
[*] a short description of what's wrong
[*] optionally: start and end points, direction, map mod and its version
[*] [b]No Telemetry needed.[/b]
[/list]
[*] [b][url=https://discord.gg/Gur2V67]Discord[/url][/b]
[/list]
