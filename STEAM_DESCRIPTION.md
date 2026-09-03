[h1]🗺️ Minidoracat MiniMap for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]⚠️ 必要前置 MOD（0.20.0 起）[/h2]
本 MOD 自 0.20.0 起需要 [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701][b]Minidoracat UI Library for B42[/b][/url]（家族共用介面函式庫）才能運作，請一併訂閱（見本頁 Required Items）。只更新本 MOD 而未訂閱函式庫會無法載入。

[hr][/hr]

[h2]✨ 這是什麼[/h2]
把「實際遊戲畫面渲染的地圖圖片」疊加到 B42 世界地圖與角落小地圖上，取代原版向量線條。使用引擎原生 ImagePyramid：多層級 LOD 縮放流暢、低 VRAM、開圖即所見。

[h2]🧰 主要功能[/h2]
[list]
[*] [b]世界地圖＆小地圖圖片化[/b]——與遊戲畫面一致；可一鍵切回原版向量樣式
[*] [b]導航目標＋沿道路路線[/b]：右鍵設目標，自動沿實際道路畫路線（偏離自動重算、深野外導到最近道路），旗標＋邊緣箭頭＋距離，抵達自動清除；可分享給陣營，隊友端也有路線
[*] [b]地圖搜尋[/b]：放大鏡鈕或右鍵「搜尋地圖…」——座標、街道名（[u]中英文都可搜[/u]）、設施類別（藥局、槍店等 20 類），依距離排序；可跳大地圖（金色脈動標記）或直接設為導航目標
[*] [b]小地圖快捷鍵＋浮動圖標[/b]：預設 /（可改鍵），沙盒沒開小地圖也能自建；常駐圖標左鍵開關、右鍵切穿透，可拖曳擺放
[*] [b]尺寸自由調[/b]：四檔預設＋拖曳邊緣自由縮放，自動記憶；按鈕列常駐不跳動
[*] [b]精準殭屍點位[/b]（預設關）：即時殭屍位置點，顏色／大小／透明度／上限可調；另有原版熱度圖開關
[*] [b]動物＆載具圖標[/b]（預設關）：野生／畜養獨立開關、物種與載具類別篩選（相容包可加狗、馬等）；兩種風格、色盲友善調色
[*] [b]世界地圖圖標[/b]：殭屍／動物／載具同款圖標上世界地圖（M），四獨立開關
[*] [b]街名＋安全屋[/b]：角落小地圖也有街名（原版沒有）；安全屋框線／圖標／名稱三開關，自己綠、陣營青、他人紅
[*] [b]玩家座標＋一鍵複製[/b]：雙地圖底部顯示 x, y, z；按鈕列複製圖示一鍵複製、右鍵複製指向處——貼上即用於 /teleportto
[*] [b]穿透模式[/b]：點擊／滾輪全部穿透直達遊戲，地圖半透明——拉大當常駐畫面不擋操作；快捷鍵 '
[*] [b]拖曳自由查看[/b]：拖動後停留檢視，點一下回到玩家
[*] [b]地圖顯示設定[/b]（齒輪鈕）：左側分類導覽＋右側目前分類，並可跨分類搜尋；分割畫面與大字型自動切單欄。所有設定即改即存、免進 ESC。整組 UI（設定／搜尋視窗、小地圖外框與按鈕列）採家族圓角深色皮膚；內建「效能說明」（逐項等級＋對策）
[*] [b]伺服器沙盒管理[/b]：可禁用各圖標、限制顯示距離、牲畜可見性四檔、陣營分享開關——改動即時生效
[*] [b]單機＆多人皆支援[/b]：僅視覺化客戶端本就同步到的資料，不提供額外情報；繁中／簡中／English／日本語四語
[/list]

[b]⚠️ -debug 注意[/b]：HOME 是引擎渲染除錯鍵（FPS 砍半）。本 MOD 預設 / 並自動遷移舊綁定，偵測到衝突會顯示橘色警告條。

[h2]🧩 地圖 MOD 支援[/h2]
搭配 [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps 地圖包[/url]：多張地圖 MOD 的小地圖圖像＋範圍框線，自動偵測、對應 MOD 啟用才顯示。
地圖 MOD 作者也可自帶支援：渲染 [b]minidoracat_minimap.pyramid.zip[/b] 放進 [b]media/minimap/[/b]，[u]不用寫 Lua[/u]。

[h2]🗺️ 內建資源點（POI）＋ Zone 圖層 API[/h2]
內建原版地圖 1669 筆資源點、20 類（軍警／醫療／商業／工農業等，各配辨識色）：染色剪影圖標（可切全彩）或半透明區塊兩種呈現，統一視窗逐類勾選。位置萃取自官方地圖檔、分類依官方房間 [u]loot 用途（loot type）[/u]判定——與地圖底圖的分區色塊（住宅／商業等圖例）可能不一致，以實際物資為準。
地下室設施（B42 basement，如民宅地下的酒吧、地下軍火庫）圖標帶「↓」角標、搜尋結果標「（地下室）」——地上看到的建築可能是別的。
另提供 `registerZoneProvider` 區域渲染框架；搭配 [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Zones addon[/url] 可顯示伺服器自訂區域（zones.json），並有專屬顯示距離（沙盒＋玩家滑條）。

[h2]🔗 系列 MOD[/h2]
本 MOD 是[b]主 MOD[/b]，單獨安裝即完整；addon 依需求選裝：
[list]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps[/url]——地圖 MOD 的圖像＋框線
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3765182411]MOD Compatibility[/url]——動物圖標追加狗、馬等
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Zones[/url]——伺服器自訂區域顯示
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3792675881]AutoDrive[/url]——GPS 導航、駕駛 HUD 與沿路網自動駕駛
[/list]

[h2]📋 MOD 資訊[/h2]
[list]
[*] [b]Mod ID:[/b] MinidoracatMiniMapFor42
[*] [b]支援版本:[/b] Build 42.20.1+
[*] 單機 / 多人皆可用（多人需伺服器啟用本 MOD）
[/list]

[h2]💬 問題回報 & 交流[/h2]
[url=https://discord.gg/Gur2V67]👉 點此加入 Discord 伺服器[/url]

[b]#地圖 #小地圖 #minimap #worldmap #Minidoracat[/b]

Workshop ID: 3763913359
Mod ID: MinidoracatMiniMapFor42
