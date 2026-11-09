[h1]Minidoracat MiniMap for B42 42.22.2-0.57.2[/h1]
[i]2026-11-10[/i]

[b]English summary[/b]
[list]
[*] Updated for Project Zomboid 42.22.2: the mini-map and world map images, POIs and parking lots were rebuilt from the new vanilla map, so places changed in 42.22 (Rosewood, the Muldraugh train station area, Ekron, West Point and more) match the game again.
[*] POIs: 1,669 → 1,695. The two Rosewood prison buildings are now one, some farm sheds are new, and 3 military checkpoints are no longer marked as military (the game turned those rooms into empty rooms). Parking: one more area; the number of lots is unchanged.
[*] Roads and navigation are unchanged.
[*] Checked on 42.22.2: in multiplayer, symbols you put on a paper map sync to the server the new 42.22 way, and the "Share new symbols with" option never shares paper map symbols.
[*] Fixed an occasional [b]IndexOutOfBoundsException[/b] error (MinidoracatMiniMap_Cleared.lua:439) when walking into or out of a POI building. It happened when part of the building unloaded while MiniMap was counting its containers. Now that count just stops and runs again later; your visited / cleared marks are not affected.
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]配合 42.22.2 的地圖更新，重做小地圖底圖、資源點與停車場[/b]：42.22 改了 Rosewood、Muldraugh 火車站一帶、Ekron、West Point 等地的建築與地面，兩張地圖的圖片、資源點圖標和停車場現在跟新地圖一致。
[*] 資源點從 1,669 筆變成 1,695 筆：Rosewood 監獄兩棟併成一棟（警察圖標跟著移位置）、多了一些農場小屋，3 個軍事崗哨不再標成軍事（官方把房間改成空房）。
[*] 停車場多一區，停車場座數不變。道路與導航不變。
[*] 支援 42.22.2：多人遊戲裡，紙本地圖上放的標記照官方 42.22 的新做法同步到伺服器，「新標記預設分享給」不會把紙本地圖的標記分享出去。
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]走進、離開資源點建築時偶爾跳出錯誤 IndexOutOfBoundsException（MinidoracatMiniMap_Cleared.lua:439）[/b]（玩家回報）：本 MOD 掃整棟容器時，建築有一部分離開載入範圍就會出這個錯。現在遇到這種情況就停下，之後照常補掃，「去過／已清空」的紀錄不受影響。
[/list]
