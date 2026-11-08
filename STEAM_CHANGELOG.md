[h1]Minidoracat MiniMap for B42 42.21.0-0.56.0[/h1]
[i]2026-11-08[/i]

[b]English summary[/b]
[list]
[*] Huge maps like Real USA now support navigation and custom roads; the road network builds in the background after you enter the world.
[*] The minimap now shows Real USA street names.
[*] Standalone worlds such as Real USA no longer get the Knox County map drawn over them.
[*] Opening the world map in Real USA no longer turns navigation off, and custom roads past coordinate 32,767 are no longer skipped.
[/list]

[h3]✨ 新增[/h3]
[list]
[*] [b]Real USA 這類超大世界可以導航[/b]：Real USA 的全國路網（約 1.1 萬條街、5.5 萬段）現在可以用來導航，自訂道路也一起支援。進入世界後，導航在背景建路網，大約 40 秒後可以用（60 fps）；長程路線要算一兩秒才出現，重算期間地圖照舊畫原本的路線。Real USA 有些地區的路沒有和主路網相連（路網資料本身斷開），到不了的目的地會顯示直線指引；畫自訂道路把它們接起來就能走。
[*] [b]Real USA 的小地圖也顯示街名[/b]：以前只有世界地圖有街名，小地圖與它的路名提示是空的。
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]在不含諾克斯郡的獨立世界（例如 Real USA），圖片化地圖仍會畫出諾克斯郡[/b]（玩家回報）：這類世界不載入原版地圖，諾克斯郡的圖卻照樣畫在相同座標上，蓋住那個世界自己的地圖。現在只有世界真的載入原版地圖時才會畫。原版世界、搭配地圖 MOD 的世界照常顯示。
[*] [b]在 Real USA 打開過世界地圖後，這一局的導航整個停用[/b]，自訂道路也不能用（玩家回報）。原因是 Real USA 的路網超過導航能處理的大小。
[*] [b]在座標超過 32,767 的地方畫的自訂道路，導航會直接略過[/b]，畫面上沒有提示（玩家回報）。Real USA 19 個出生區有 17 個在這個範圍外。
[/list]
