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
[*] [b]世界地圖＆角落小地圖圖片化[/b]——建築、道路、植被與遊戲畫面一致；不習慣可一鍵切回原版向量樣式（圖標等其他功能照常）
[*] [b]小地圖快捷鍵[/b]：預設 /（斜線，M 鍵右方）開關（可改鍵）；伺服器沙盒沒開小地圖也能自建；舊版預設 HOME 首次進遊戲自動遷移為 /
[*] [b]浮動開關圖標[/b]：常駐小圖標點擊即開關小地圖，免快捷鍵；可拖曳擺放、位置自動記憶、hover 顯示當前快捷鍵（可於設定關閉）
[*] [b]尺寸自由調[/b]：四檔預設＋拖曳小地圖邊緣自由縮放，自動記憶
[*] [b]按鈕列常駐[/b]：不再滑鼠懸停才展開；齒輪開統一設定視窗——雙欄分區可收合、全部展開／收合，免進 ESC 選項
[*] [b]導航目標[/b]：右鍵地圖設目標——旗標＋邊緣方向箭頭＋直線距離，抵達自動清除；可一鍵分享給陣營成員
[*] [b]精準殭屍點位[/b]（預設關）：即時殭屍位置點，顏色／大小／透明度／數量上限可調
[*] [b]殭屍熱度圖[/b]開關（預設關）
[*] [b]動物圖標[/b]（預設關）：即時顯示附近動物——野生／畜養獨立開關、9 個內建物種篩選；搭配 [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3765182411]第三方 MOD 相容包[/url] 可追加狗、馬等已支援物種；地圖符號或彩色物品圖兩種風格，大小、透明度、顏色可調（色盲友善 8 色）
[*] [b]載具圖標[/b]（預設關）：方向盤圖標顯示附近載具；一般／重型／性能／特勤（警燈車）類別篩選，大小、透明度、顏色可調
[*] [b]世界地圖圖標[/b]：殭屍／動物／載具圖標也能顯示在世界地圖（M）——四個獨立開關，風格、顏色與篩選跟隨小地圖設定；世界地圖新增爪印按鈕直開設定視窗
[*] [b]街名顯示[/b]：角落小地圖也有街名（原版只有世界地圖有）；中文街名 MOD 同步生效
[*] [b]安全屋範圍框線[/b]：自己綠框、他人紅框
[*] [b]拖曳自由查看[/b]：拖動後停留檢視，點一下回到玩家；拖離期間顯示回中提示（同導航軟體）
[*] [b]伺服器沙盒管理[/b]：可禁用殭屍點位／熱度圖／動物／載具圖標；限制殭屍／動物／載具／安全屋框線顯示距離；設定安全屋顯示模式、牲畜四檔可見性與陣營分享——管理面板改動即時生效
[*] [b]單人＆多人皆支援[/b]：單機隨裝隨用；多人由伺服器啟用（PZ 模組清單由伺服器決定，玩家無法私載），管理員以上述沙盒選項控管——本 MOD 僅視覺化客戶端本來就同步到的資料，不提供額外情報
[*] [b]多語[/b]：繁體中文／簡體中文／English／日本語
[/list]

[b]⚠️ -debug 模式使用者請注意[/b]：HOME 是引擎隱藏的渲染除錯鍵——按下會切換世界渲染路徑（FPS 砍半、地面積雪外觀改變），並與任何綁在 HOME 的快捷鍵同時觸發。本 MOD 預設鍵已改為 /（斜線）並自動遷移舊安裝；若你仍把開關綁在 HOME，請改鍵。遊戲內偵測到綁定衝突、或渲染已被切至舊管線時，小地圖會直接顯示橘色警告條提示復原方式。

[h2]🧩 地圖 MOD 支援[/h2]
搭配 [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]Minidoracat MiniMap - MOD Maps[/url] 地圖包 addon：內含多張地圖 MOD 的
小地圖圖像與範圍框線（含名稱、多語翻譯），[u]自動偵測[/u]——對應的地圖 MOD
有啟用才顯示，沒裝不誤畫；裝了地圖包還會多出專屬選項（MOD 地圖區塊開關、
框線開關、框線顏色、框線透明度）。
地圖 MOD 作者也可自帶支援：把自己地圖渲染成同名
[b]minidoracat_minimap.pyramid.zip[/b] 放進 [b]media/minimap/[/b]，
[u]完全不用寫 Lua[/u]，本 MOD 會自動偵測並疊加顯示（自動對位，疊在基底之上）。

[h2]🗺️ 內建資源點（POI，0.8.0+）＋ Zone 圖層 API（0.7.0+）[/h2]
[b]裝本體即見資源點[/b]：內建原版地圖的 636 筆資源點、14 類（軍事、警察、槍店、醫療、
藥局、消防、圖書、學校、超市、加油站、五金、戶外、監獄、倉儲，各配可辨識色）。
預設「圖標模式」在每個資源點畫染色剪影圖標（不鋪滿標籤），可切換全彩圖標，
大小與透明度滑條可調；另可開
「顯示資源點區塊」（半透明色塊＋名稱），並於統一設定視窗「資源點圖標」小節逐類勾選
（列首帶類別小圖）、齒輪面板一鍵開關。
[u]資源點資料直接萃取自官方原版地圖檔[/u]（非手工標註）——若發現位置或分類有誤，
屬官方資料本身的錯誤，需待官方修正後、本 MOD 隨更新同步。
本 MOD 同時提供區域渲染框架：`registerZoneProvider(ownerModId, providerFn, optionLabelKey)`
讓 addon 只需提供矩形區域資料，本 MOD 負責在小地圖與世界地圖上繪製半透明填色、框線、
置中名稱與圖標；給了 optionLabelKey 就自動獲得一顆專屬母開關。搭配區域顯示 addon
[url=https://steamcommunity.com/sharedfiles/filedetails/?id=3768276209]Minidoracat MiniMap Zones[/url]（Mod ID: MinidoracatMiniMapZonesFor42）可額外顯示伺服器
自訂區域（`zones.json`，外部程式可寫入）。未安裝 addon 時不影響本 MOD 其餘功能。

[h2]🔗 系列 MOD[/h2]
本 MOD 是系列[b]主 MOD[/b]，單獨安裝即可完整使用；以下 addon 依需求選裝（皆需本 MOD）：
[list]
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763914102]MOD Maps[/url]——地圖 MOD 圖像包：地圖 MOD 的小地圖圖像＋範圍框線
[*] [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3765182411]MOD Compatibility[/url]——第三方 MOD 相容包：動物圖標追加狗、馬等物種
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
