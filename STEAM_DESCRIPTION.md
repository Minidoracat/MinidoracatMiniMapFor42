[h1]🗺️ Minidoracat MiniMap for B42[/h1]
[h3]By Minidoracat[/h3]

[hr][/hr]

[h2]✨ 這是什麼[/h2]
把「實際遊戲畫面渲染的地圖圖片」直接疊加到 B42 遊戲內世界地圖上，
取代原版的向量線條風格。使用 B42 引擎原生 ImagePyramid 機制：
[list]
[*] 多層級 LOD——縮放流暢，不再卡頓
[*] 引擎級紋理快取與非同步載入——低 VRAM 佔用
[*] 開圖即所見：建築、道路、植被與遊戲內視覺一致
[/list]

[h2]🧰 主要功能[/h2]
[list]
[*] [b]世界地圖＆角落小地圖圖片化[/b]——與遊戲畫面一致；不習慣可一鍵切回原版向量樣式，其他功能照常
[*] [b]小地圖快捷鍵[/b]：預設 /（斜線，M 鍵右方），可改鍵；伺服器沙盒沒開小地圖也能自建
[*] [b]浮動開關圖標[/b]：常駐小圖標——左鍵開關小地圖、右鍵切換穿透模式；可拖曳擺放（自動記憶）、hover 顯示當前快捷鍵（可關閉）
[*] [b]尺寸自由調[/b]：四檔預設＋拖曳邊緣自由縮放，自動記憶
[*] [b]按鈕列常駐[/b]：不再懸停才展開；齒輪開統一設定視窗——雙欄分區可收合，免進 ESC 選項
[*] [b]導航目標[/b]：右鍵地圖設目標——旗標＋邊緣方向箭頭＋距離，抵達自動清除；可一鍵分享給陣營
[*] [b]精準殭屍點位[/b]（預設關）：即時殭屍位置點，顏色／大小／透明度／上限可調
[*] [b]殭屍熱度圖[/b]開關（預設關）
[*] [b]動物圖標[/b]（預設關）：即時顯示附近動物——野生／畜養獨立開關、9 個內建物種篩選（[url=https://steamcommunity.com/sharedfiles/filedetails/?id=3765182411]相容包[/url]可追加狗、馬等）；符號或物品圖兩種風格，大小、透明度、顏色可調（色盲友善 8 色）
[*] [b]載具圖標[/b]（預設關）：方向盤圖標顯示附近載具；一般／重型／性能／特勤篩選，大小、透明度、顏色可調
[*] [b]世界地圖圖標[/b]：殭屍／動物／載具圖標也上世界地圖（M）——四個獨立開關，風格與篩選跟隨小地圖；爪印按鈕直開設定視窗
[*] [b]街名顯示[/b]：角落小地圖也有街名（原版只有世界地圖有）；中文街名 MOD 同步生效
[*] [b]安全屋範圍框線[/b]：自己綠框、他人紅框
[*] [b]拖曳自由查看[/b]：拖動後停留檢視，點一下回到玩家；拖離期間顯示回中提示
[*] [b]玩家座標顯示＋一鍵複製[/b]：小地圖底部顯示目前 x, y, z（可關）；XY 鈕一鍵複製、右鍵可複製指向處座標——貼上即用於 /teleportto 等指令
[*] [b]穿透模式（點擊穿透）[/b]：點擊／滾輪／右鍵全部穿透直達遊戲世界，地圖本體半透明（滑條可調）——拉大當常駐畫面不擋操作、不擋視線；快捷鍵 '、浮動圖標右鍵或設定切換
[*] [b]伺服器沙盒管理[/b]：可禁用各圖標、限制顯示距離、設定安全屋顯示、牲畜四檔可見性與陣營分享——管理面板改動即時生效
[*] [b]單人＆多人皆支援[/b]：單機隨裝隨用；多人由伺服器啟用、管理員以沙盒選項控管——本 MOD 僅視覺化客戶端本來就同步到的資料，不提供額外情報
[*] [b]多語[/b]：繁體中文／簡體中文／English／日本語
[/list]

[b]⚠️ -debug 使用者請注意[/b]：HOME 是引擎隱藏的渲染除錯鍵（切換渲染路徑——FPS 砍半、積雪外觀改變）。本 MOD 預設鍵已改為 / 並自動遷移舊安裝；若仍綁 HOME 請改鍵。偵測到綁定衝突或舊渲染管線時，小地圖會顯示橘色警告條與復原方式。

[h2]🧩 地圖 MOD 支援[/h2]
搭配 [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]Minidoracat MiniMap - MOD Maps[/url] 地圖包 addon：內含多張地圖 MOD 的小地圖圖像與範圍框線（含名稱、多語），[u]自動偵測[/u]——對應地圖 MOD 有啟用才顯示；裝了地圖包還多出專屬選項（區塊開關、框線開關／顏色／透明度）。
地圖 MOD 作者也可自帶支援：把地圖渲染成 [b]minidoracat_minimap.pyramid.zip[/b] 放進 [b]media/minimap/[/b]，[u]完全不用寫 Lua[/u]——本 MOD 自動偵測並疊加在基底之上。

[h2]🗺️ 內建資源點（POI，0.8.0+）＋ Zone 圖層 API（0.7.0+）[/h2]
[b]裝本體即見資源點[/b]：內建原版地圖 1720 筆資源點、20 類（軍事、警察、槍店、醫療、藥局、消防、圖書、學校、超市、加油站、五金、戶外、監獄、倉儲、電器行、教堂、農場、工業、零售、餐飲，各配辨識色）。預設畫染色剪影圖標（可切全彩，大小／透明度滑條可調）；另可開「資源點區塊」（半透明色塊＋名稱），統一設定視窗逐類勾選。[u]資料直接萃取自官方地圖檔[/u]——位置或分類有誤屬官方資料錯誤，待官方修正後隨更新同步。另提供區域渲染框架：`registerZoneProvider(ownerModId, providerFn, optionLabelKey)` 讓 addon 只給矩形區域資料，本 MOD 負責雙地圖繪製填色、框線、名稱與圖標（給 optionLabelKey 即有專屬開關）。搭配 [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Minidoracat MiniMap Zones[/url]（MinidoracatMiniMapZonesFor42）可顯示伺服器自訂區域（`zones.json`）。未裝 addon 不影響其餘功能。

[h2]🔗 系列 MOD[/h2]
本 MOD 是系列[b]主 MOD[/b]，單獨安裝即可完整使用；以下 addon 依需求選裝（皆需本 MOD）：
[list]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps[/url]——地圖包：地圖 MOD 的小地圖圖像＋範圍框線
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3765182411]MOD Compatibility[/url]——相容包：動物圖標追加狗、馬等物種
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Zones[/url]——伺服器自訂區域顯示（zones.json；需本 MOD 0.8.0+）
[/list]

[h2]📋 MOD 資訊[/h2]
[list]
[*] [b]Mod ID:[/b] MinidoracatMiniMapFor42
[*] [b]支援版本:[/b] Build 42.20.0+
[*] 單機 / 多人皆可用（多人需伺服器啟用本 MOD）
[/list]

[h2]💬 問題回報 & 交流[/h2]
[url=https://discord.gg/Gur2V67]👉 點此加入 Discord 伺服器[/url]

[h2]📺 關注作者[/h2]
[url=https://www.twitch.tv/minidoracat]🎬 Twitch 直播頻道[/url]

[b]#地圖 #小地圖 #minimap #worldmap #Minidoracat[/b]

Workshop ID: 3763913359
Mod ID: MinidoracatMiniMapFor42
