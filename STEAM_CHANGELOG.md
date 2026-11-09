[h1]Minidoracat MiniMap for B42 42.21.0-0.57.1[/h1]
[i]2026-11-09[/i]

[b]English summary[/b]
[list]
[*] When the sandbox option "Allow Mini-Map" is off, the mini-map now comes back by itself when you load the game, the way you left it: open if it was open, closed if you closed it. On servers that also turn off "Allow World Map" it won't open by itself; press [b]/[/b] when you want it.
[*] Fixed navigation saying "no road" for the rest of the session after a rare internal error until you reloaded the save. Now only that one search fails; move a bit or pick another destination and it recalculates.
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]沙盒沒開「允許小地圖」時，每次進遊戲都要再按一次 / 才有小地圖[/b]（玩家回報）：現在照上次離開時的開關狀態自動出現，開著離開就開著、關著離開就維持關著，位置照之前拖到的地方。
[*] 開關狀態每個存檔各記一份：新存檔、以及更新前從沒按過 / 的存檔，第一次進遊戲就會看到小地圖，不想要就按 / 關掉，下次就不會出現。分割畫面每位玩家各有一份，手把輪盤也有小地圖的開關。
[*] 沙盒連「允許世界地圖」都關的伺服器不會自動出現，照樣可以按 / 開。
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]導航找路時遇到少見的內部錯誤，這一局之後全部「找不到道路」[/b]，要重新進入存檔才恢復（玩家回報「換個存檔再回來又好了」）：現在只當作那一次找不到路，走遠一點或換個目的地就會重算。
[/list]
