[h1]Minidoracat MiniMap for B42 42.22.2-0.58.0[/h1]
[i]2026-11-12[/i]

[b]English summary[/b]
[list]
[*] Servers with many custom zones (Custom Zones add-on): zone names no longer pile up into an unreadable blob when you zoom out. Where names would overlap only one is shown, and the rest appear as you zoom in. The names that stay don't change while you pan or walk.
[*] Zooming all the way out with many custom zones is much faster: with 2,000 zones on screen the world map went from about 55 FPS back to about 190 FPS (Ryzen 9 9950X3D, 1080p, uncapped).
[*] Fixed the player coordinates at the bottom of the world map being hidden behind the button row. It happened in game windows narrower than about 1,840 px (for example 1600x900, 1366x768, 1280x720) or with a larger game font. The coordinates now move above the buttons when they would be covered.
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]自訂區域很多的伺服器，地圖拉遠後區域名稱疊成一片黑、讀不出來[/b]（裝了「自訂區域」這類擴充的伺服器才會遇到）：現在名稱不重疊。會疊在一起的地方只顯示一個，其他的拉近後才出現；平移地圖或走動時，留下的名稱不會換來換去。靠近地圖邊框的名稱會被框切掉一部分（以前是整個放不下就不顯示），所以小地圖上看得到的名稱比以前多。只有「地圖顯示設定 → 自訂區域 → 區域名稱不受縮放限制」勾選時（預設）這樣做；取消勾選是舊做法：小型區域的名稱只在拉近時顯示，名稱不避開重疊。內建資源點的名稱不受影響。
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]世界地圖底部的玩家座標被右下角的按鈕列蓋住[/b]（玩家回報）：遊戲視窗寬度不到約 1,840 像素（例如 1600×900、1366×768、1280×720），或把遊戲字級調大時，置中的座標會躲到按鈕後面。現在會被蓋住時，座標改顯示在按鈕列上方；視窗夠寬時位置不變，小地圖不受影響。
[/list]

[h3]⚡ 效能[/h3]
[list]
[*] [b]自訂區域很多時，把地圖拉到最遠會明顯掉幀[/b]（區域越多越嚴重；500 筆時世界地圖拉到最遠，幀率就少掉四成）：時間大多花在每一幀重畫全部區域的名稱。名稱不重疊之後只畫留下的那些，速度和完全不畫名稱幾乎一樣：2,000 筆區域全部在畫面裡時，世界地圖拉到最遠從約 55 FPS 回到約 190 FPS，小地圖拉到最遠從約 110 FPS 回到 1,000 FPS 上下（Ryzen 9 9950X3D、1080p、不限幀）。平常遊玩的縮放本來就不卡，沒有差別。
[/list]
