[h1]🗺️ Minidoracat MiniMap for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]⚠️ 必要前置 MOD（0.20.0 起）[/h2]
0.20.0 起需要 [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701][b]Minidoracat UI Library for B42[/b][/url]。請從 Required Items 一併訂閱；缺少此前置會無法載入。

[hr][/hr]

[h2]✨ 這是什麼[/h2]
以地圖資料與遊戲材質預先渲染全彩頂視底圖，將屋頂、樹木、道路與地表的色彩層次呈現在 B42 世界地圖與角落小地圖上。搭配資源點圖標、街名搜尋與道路導航，看地圖、找物資與規劃路線一次完成。

[h2]底圖特色[/h2]
[list]
[*] [b]從地圖與材質重新製圖[/b]——依地圖中的建築、植物與地表材質合成頂視底圖，呈現各地區的色彩與景觀。
[*] [b]MOD 地圖也能補製圖資[/b]——搭配 MOD Maps 地圖包，已收錄的地圖即使沒有自帶原生影像，也能顯示另行渲染的底圖；支援範圍以地圖包收錄及作者提供的相容圖資為準。
[*] [b]原生分級縮放[/b]——採用遊戲引擎的 ImagePyramid，依縮放載入不同解析度的圖磚；可隨時切回原版向量地圖。
[/list]

底圖為預先製作的影像，不會即時反映玩家建造、拆除或砍樹；殭屍、動物與載具圖標則依客戶端已取得的資料更新。

[h2]🧰 主要功能[/h2]
[list]
[*] [b]導航目標＋沿道路路線[/b]：右鍵設目標，沿道路規劃路線；偏離重算、深野外導向最近道路。旗標＋邊緣箭頭＋距離，抵達自動清除；陣營分享後隊友也有路線
[*] [b]地圖搜尋[/b]：放大鏡或右鍵「搜尋地圖…」查座標、街名（[u]原名／譯名[/u]）、20 類設施，距離排序；可跳大地圖（金色脈動標記）或設導航目標。「MOD 地圖：名稱」只標示已確認的街道來源，不代表有錯
[*] [b]小地圖快捷鍵＋浮動圖標[/b]：預設 /（可改鍵），沙盒沒開小地圖也能自建；常駐圖標左鍵開關、右鍵切穿透，可拖曳擺放
[*] [b]尺寸自由調[/b]：四檔預設＋拖曳邊緣自由縮放，自動記憶；按鈕列常駐不跳動
[*] [b]精準殭屍點位[/b]（預設關）：即時殭屍位置點，顏色／大小／透明度／上限可調；另有原版熱度圖開關
[*] [b]動物＆載具圖標[/b]（預設關）：野生／畜養獨立開關、物種與載具類別篩選（相容包可加狗、馬等）；兩種風格、色盲友善調色
[*] [b]世界地圖圖標[/b]：殭屍／動物／載具同款圖標上世界地圖（M），四獨立開關
[*] [b]街名＋安全屋[/b]：角落小地圖也有街名（原版沒有）；安全屋框線／圖標／名稱三開關，自己綠、陣營青、他人紅
[*] [b]玩家座標＋一鍵複製[/b]：雙地圖底部顯示 x, y, z；按鈕列複製圖示一鍵複製、右鍵複製指向處——貼上即用於 /teleportto
[*] [b]穿透模式[/b]：點擊／滾輪全部穿透直達遊戲，地圖半透明——拉大當常駐畫面不擋操作；快捷鍵 '
[*] [b]拖曳自由查看[/b]：拖動後停留檢視，點一下回到玩家
[*] [b]地圖顯示設定[/b]（齒輪鈕）：左側分類、右側設定＋跨分類搜尋；分割畫面／大字型自動切單欄。即改即存、免 ESC；設定／搜尋／小地圖共用圓角深色皮膚，內建逐項效能說明與對策
[*] [b]伺服器沙盒管理[/b]：可禁用各圖標、限制顯示距離、牲畜可見性四檔、陣營分享開關——改動即時生效
[*] [b]單機＆多人皆支援[/b]：僅視覺化客戶端本就同步到的資料，不提供額外情報；繁中／簡中／English／日本語四語
[/list]

[b]⚠️ -debug 注意[/b]：HOME 是引擎渲染除錯鍵（FPS 砍半）。本 MOD 預設 / 並自動遷移舊綁定，偵測到衝突會顯示橘色警告條。

[h2]🧩 地圖 MOD 支援[/h2]
選用 [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps 地圖包[/url]，自動顯示已啟用且已收錄地圖的圖像與範圍框線。併用需本體 42.20.4-0.27.0+、地圖包 42.20.4-0.9.0+，更新後重啟遊戲。重疊區依地圖優先序採用，街名可能不進搜尋／導航；[url=https://steamcommunity.com/workshop/filedetails/discussion/3763913359/569297034317714443/]道路資料說明[/url]。
地圖 MOD 作者也可自帶支援：渲染 [b]minidoracat_minimap.pyramid.zip[/b] 放進 [b]media/minimap/[/b]，[u]不用寫 Lua[/u]。

[h2]🗺️ 內建資源點（POI）＋ Zone 圖層 API[/h2]
原版地圖 1669 筆資源點、20 類（軍警／醫療／商業／工農業等），各有辨識色。支援染色剪影或全彩圖標、半透明區塊，設定視窗可逐類開關。位置取自官方地圖；分類依房間 [u]loot 用途[/u]，不一定符合地圖分區色塊，以實際物資為準。
地下室設施（B42 basement，如民宅地下的酒吧、地下軍火庫）圖標帶「↓」角標、搜尋結果標「（地下室）」——地上看到的建築可能是別的。
另提供 `registerZoneProvider` 區域渲染框架；搭配 [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Zones addon[/url] 可顯示伺服器自訂區域（zones.json），並有專屬顯示距離（沙盒＋玩家滑條）。

[h2]🔗 系列 MOD[/h2]
安裝必要前置後，[b]主 MOD[/b] 即可完整使用；addon 依需求選裝：
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

[url=https://github.com/Minidoracat/MinidoracatAutoDriveFor42/issues/new?template=road-data.yml][b]道路／導航線問題回報[/b][/url]：線畫到路外、缺路或繞遠，請附[b]包含導航線與座標的截圖＋可複製的文字座標[/b]，簡述哪裡不對。可補起終點、方向、地圖 MOD／版本；[b]不需 Telemetry[/b]。請在地圖上的問題點按右鍵「複製此處座標」。

[h2]☕ 支持作者[/h2]
MOD 永遠免費。喜歡的話可以請我喝杯咖啡，贊助會用在伺服器與 MOD 開發上。
[url=https://ko-fi.com/minidoracat][img]https://raw.githubusercontent.com/Minidoracat/workshop-resources/refs/heads/main/badges/badge_kofi.png[/img][/url]

[b]#地圖 #小地圖 #minimap #worldmap #Minidoracat[/b]

Workshop ID: 3763913359
Mod ID: MinidoracatMiniMapFor42
