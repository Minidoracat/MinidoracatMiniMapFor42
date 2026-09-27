<!-- Steam discussion source (English); road lists mirror MOD Maps STEAM_DISCUSSION_support_EN.md (from docs/road-data.md) — keep in sync -->
<!-- 討論串網址：https://steamcommunity.com/workshop/filedetails/discussion/3763913359/586187095760051259/ -->
<!-- 標題：📢 MOD Map Road Navigation Notice: Street Names, Search & Routing -->

[b]繁體中文版：[/b][url=https://steamcommunity.com/workshop/filedetails/discussion/3763913359/569297034317714443/]MOD 地圖道路導航告知[/url]

[b]MiniMap street names, street search and navigation only work on maps whose author ships road data. Image support is not a navigation or AutoDrive guarantee.[/b]

[h2]Street names, search and navigation come from the map author's road data[/h2]
Street labels, street search, navigation and the AutoDrive road network all come from the native streets.xml that the map author ships inside the map MOD. Maps without road data still show their image, but that area has no street names, no search results and no navigation — this is not a missing translation.
Road coordinates, widths, bends and junctions must match the actual road. Missing, disconnected or offset data can cause missing routes, detours or off-road navigation. Map overlap and priority also matter: require only orders MiniMap and its addons and does not make conflicting maps compatible. In multiplayer the server Map= order decides priority, and lower-priority street sections can be excluded so both original and translated names return no result.
The [b]MOD map: map name[/b] label in street search identifies a known source; it is not an error flag or a driving certification.

[h2]🧭 For map authors: how to ship road data[/h2]
A MiniMap-specific integration script is normally unnecessary; ship a correct native streets.xml:
[list]
[*] Place it inside your mod's active common or version directory: media/maps/<map folder>/streets.xml. The folder must be the actual map directory enabled for the world, not the Workshop title.
[*] Use the current game's street format; each polyline needs at least two valid points and a valid road width.
[*] Draw polylines along the road centre, with coordinates, widths, bends and junctions matching the real road; do not cut across grass, buildings or the inside of bends.
[*] Check connections at junctions and map seams; missing or disconnected segments cause detours or no route.
[*] Map images and worldmap.xml do not replace streets.xml. Restart the game after changing road files; navigation does not hot-reload.
[/list]
MiniMap does not detect the physical road surface to correct coordinates; the bundled RoadPatches only fix specific vanilla roads.

[h2]🛠️ Roads made or fixed by the MOD Maps pack[/h2]
[list]
[*] [b]Constown, KY[/b]: 37 added roads. Roads missing from the author's data are added by the MOD Maps pack, named "Constown Rd 01 (MiniMap)" to "Constown Rd 37 (MiniMap)", searchable and routable. If the author later ships road data, the game switches to the author's roads automatically.
[*] [b]Camden County[/b]: 3 gap bridges. Author roads stopped short of junctions so navigation/AutoDrive could not reach them; they now connect to the network and keep the author's street names.
[*] [b]Daisy County[/b]: 44 outline roads converted to centre lines, so names are not shown twice and routes follow the road centre.
[*] [b]Muldraugh 1993[/b]: 913 street labels that exactly duplicate the vanilla map are hidden on display only; navigation roads are not deleted, and uncertain or partial overlaps keep their labels.
[/list]

[h2]✅ Maps with author road data (22)[/h2]
[list]
[*] AnruisiTown (Military Bastion): 59 streets
[*] Camden County: 40 streets
[*] Daisy County: 44 streets
[*] Ed's Auto Salvage: 3 streets
[*] LittleTownship: 4 streets
[*] Maplewood: 12 streets
[*] Megurigaoka, Kanagawa: 2 streets
[*] Muldraugh 1993: 1092 streets
[*] Raven Creek: 45 streets
[*] Raven Creek (Kardinal port): 45 streets
[*] SecretZ Checkpoint 5: 1 streets
[*] SecretZ Checkpoint 8: 2 streets
[*] SecretZ March Ridge Research Facility: 2 streets
[*] SecretZ West Point Bridge Checkpoint: 4 streets
[*] SecretZ Riverside Checkpoint 1: 2 streets
[*] SecretZ Riverside Checkpoint 2: 4 streets
[*] Tikitown & PowerPlant: 99 streets
[*] West Point Expansion: 18 streets
[*] WILDSTEEL - Fort Spiffo: 4 streets
[*] Clover Lake Farmhouse: 1 streets
[*] Greenport, KY: 15 streets
[*] West Point: The Bridge Citadel: 4 streets
[/list]

[h2]❌ Maps without author road data (79)[/h2]
These maps show their image, but have no street names, search or navigation (except the roads we added above).
[list]
[*] Muldraugh Fire Dept
[*] Estate 39
[*] Atlas Underground Complex (Surface)
[*] Chinatown Expansion
[*] Chinatown
[*] Asakusa Lake Town
[*] Ashenwood
[*] Atlanta Safe Zone
[*] Atlanta Tower Survival
[*] Atlanta
[*] Blackpine County
[*] Cathaya Valley 2.0 Highway
[*] Cathaya Valley 2.0
[*] Constown, KY
[*] Coryerdon
[*] Dawn Town
[*] EchoCreek Military Base
[*] Erika's Furniture Store
[*] Floatopia
[*] Foxtrot Warehouse
[*] Fort Benning
[*] Fort JadeLake
[*] Fort Waterfront
[*] Fort Boonesborough
[*] Grapeseed
[*] Greenleaf
[*] Hartburg, KY
[*] Hunter's Base
[*] Hunter's Base (Small)
[*] Hazelnut Manor
[*] Hazelnut Manor (Poor)
[*] Iris Eyot
[*] KillMingLake
[*] Kingsmouth North
[*] White Forest
[*] Louisville Riverboat
[*] Muldraugh Checkpoint - Overpass
[*] Fort Preston
[*] Nekomata Ridge
[*] Nettle Township
[*] Path of Zenith
[*] New Coalfield
[*] Raccoon City
[*] Riverside Mansion (Unofficial)
[*] RustBury
[*] Safeharbor Garrison
[*] SafeWayHamlet
[*] Sunset Lake Town
[*] Sunset Tower
[*] SecretZ Bunker 3
[*] SecretZ Checkpoint 1
[*] SecretZ Checkpoint 6
[*] SecretZ Deerhead Lake Base
[*] SecretZ Louisville Military Complex
[*] SecretZ Train Depot Refugee Camp
[*] SecretZ Crossroads Checkpoint
[*] SecretZ North Checkpoint
[*] SecretZ The Mall
[*] Taibei Road
[*] Taylorsville
[*] Trapala Lake Town
[*] Trelai 4x4 (Kardinal port)
[*] Vila Z
[*] Willowbrook Bastion
[*] Willowbrook Bastion 2026
[*] Bunker 42
[*] New Ellroy
[*] Shadyside
[*] White Forest Ridge
[*] Yanghu Town
[*] Begonia Town
[*] Frogtown
[*] Haven Fall
[*] Macon (TWD)
[*] Xixi's Serene Cottage
[*] VaultTec Vault - Louisville
[*] VaultTec Vault - Muldraugh
[*] VaultTec Road
[*] VaultTec Vault - Rosewood
[/list]

[h2]📝 Testing and reports[/h2]
Readable road data does not guarantee successful AutoDrive; driving still depends on geometry, width, obstacles and real conditions. Verify bends, junctions and cross-map connections in game.
Please include game/mod versions, the map Workshop link, SP/MP mode, start and end coordinates, screenshots of the route versus the road, and relevant log excerpts. Remove credentials and private server details before sharing logs.

[h2]Related topics[/h2]
[list]
[*][url=https://steamcommunity.com/workshop/filedetails/discussion/3763914102/586187095760050473/]MOD Maps pack: MOD Map Support Notice[/url]
[*][url=https://steamcommunity.com/workshop/filedetails/discussion/3792675881/586187095760051144/]AutoDrive road requirements and known issues[/url]
[*][url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps pack (map images)[/url]
[/list]
