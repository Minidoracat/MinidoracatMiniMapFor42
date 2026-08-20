Minidoracat MiniMap - Zomboid/Lua/MinidoracatMiniMap 目錄說明（format v1）

本檔由 MOD 在檔案不存在時自動產生，之後不會再覆寫（你可以在上面加註記）；
刪掉不影響 MOD 運作，下次啟動會補回。
英文版與日文版在同目錄：_README_EN.txt、_README_JP.txt。
完整契約（含全部邊界情況）在 MOD 原始碼檔頭：
  42/media/lua/server/MinidoracatMiniMapPlayerExport.lua
  42/media/lua/shared/MinidoracatMiniMapPOIExport.lua

== 這個目錄有什麼 ==

  poi_blocks.json           內建資源點（POI）區塊。每次啟動寫一次，內容隨 MOD
                            版本走，與存檔無關。欄位解釋見下一節。
  players_存檔名.json       玩家座標。要在沙盒開啟「匯出玩家座標檔」才會產生，
                            之後每 N 秒（沙盒可調，預設 5）整檔重寫。
                            存檔名＝多人的伺服器名／單機的存檔資料夾名。
  _README_CH.txt            本檔（繁體中文）。
  _README_EN.txt            本檔（English）。
  _README_JP.txt            本檔（日本語）。

  另外 Zones addon 會在隔壁目錄 MinidoracatMiniMapZones/ 放 zones.json
  （伺服器自訂區域），那是另一個 MOD 的產物。

== poi_blocks.json 的欄位 ==

一條目一行、條目間逗號在行首（方便 diff）。同版本內輸出逐 byte 相同，
MOD 更新才會變。

  v            格式版本，目前是 1。讀到別的值請中止。
  modversion   寫檔當下安裝的 MOD 版本（取不到時 "unknown"）。破壞性操作前
               應比對伺服器實際安裝的 MOD 版本（mod.info 的 modversion=），
               不等＝檔案陳舊（上次寫檔失敗殘留了舊檔），請中止。
  count        全部分類加總的條目數。實際條目數不等於 count＝檔案不完整，
               請中止。
  categories   分類 → 條目陣列。分類鍵是內部識別字（純小寫字母，如 gas、
               grocery、industry……共 20 類）。

  每筆條目的欄位：
    b   [x, y, w, h]：整棟建築外框。世界 square 座標，x/y 是左上角、w/h 是
        尺寸，涵蓋 tiles [x, x+w-1]。這是整棟重置的刪 chunk 依據；
        chunk 換算＝floor(tile/8)（B42 chunk＝8×8 tiles，
        存檔檔案 map/<cx>/<cy>.bin）。契約允許 b 缺席（測試 fixture 情境；
        目前官方烘焙資料一律有 b）——別把 b 寫成必填欄。
    r   [[x, y, w, h], ...]：主分類觸發房的矩形，面積大→小排列
        （第一筆是圖標錨點）。
    u   選配（主 MOD 42.20.3-0.17.0+）："u":1＝地下條目（B42 basement，
        主分類房的主樓層在地下）。只有地下條目會輸出這個欄，地上條目
        沒有它（不會出現 "u":0）。additive 擴充：工具端照「忽略未知鍵」
        慣例處理即可。chunk 檔不分樓層，u 不影響刪 chunk 的範圍。

== players_存檔名.json 的欄位 ==

第一行是 metadata，之後每個玩家一行，最後一行 ]} 閉合。

  v                 格式版本，目前是 1。
  modversion        寫檔當下安裝的 MOD 版本。
  save              存檔名。應該等於你要操作的存檔目錄名，不等就別用這份檔。
  ts                寫檔時刻（真實時間 epoch 毫秒）。新鮮度就看這個。
  interval          當時生效的匯出週期（秒，1-300）。
  offlineAuthority  固定 "observed-subset"。讀到別的值代表語意換版了，請中止。
  offlineIncluded   沙盒是否要求輸出離線筆。false＝一筆離線都沒有，這不等於
                    「沒有離線角色」。
  offlineSince      離線歷史的起點（epoch 毫秒）。比這個時間更早登出的角色不在
                    清單裡。跨重啟會延續；讀回失敗、匯出被關掉後重新開啟、或那份
                    檔案本身沒有離線筆時，會重設成當下。
  offlineTruncated  離線清單是否曾因為條目上限（2000）被裁掉最舊的幾筆。
  online            清單裡 online:true 的筆數。
  count             players 的總筆數。
  players           玩家陣列，每筆：
                      name    玩家帳號名（username）。要踢人就用這個。
                      idx     分割畫面 slot（0-3）。
                      steamId Steam64（17 位字串）。取不到時是空字串——非 Steam
                              伺服器、或那個玩家的客戶端還沒回報過。
                              信任等級見下面「關於 steamId」。
                      online  這一刻是否在線。
                      x, y    世界座標（整數格）。存檔 chunk ＝ floor(x/8)。
                      z       樓層，地下室是負數。
                      seen    這組座標是什麼時候觀測到的（epoch 毫秒）。

  唯一鍵是 (name, idx)，不是 name：同一個帳號在同一台電腦分割畫面可以有多個角色
  站在不同地方。只按 name 去重會直接丟掉一個真實玩家的座標；出現重複的
  (name, idx) 代表檔案不可信，請中止整份文件而不是靜默去重。

== 最重要的一件事：兩種筆的證明力不一樣 ==

  online:true 的筆是完整的。
    來源是引擎的權威在線清單，掃過所有連線的所有分割畫面 slot。
    可以用它下這個結論：「這一刻沒有在線玩家在這塊地上」。
    如果有任何一個在線玩家的名字無法無損寫出、或出現重複的 (name, idx)，
    本 MOD 會整輪不寫檔，讓這份檔案因為 ts 過期被你擋下——絕不會偷偷少寫一個人。

  online:false 的筆只是「本 MOD 觀測到的子集」，永遠不完整。
    至少四種人會缺席：本 MOD 開始記錄之前就登出的、沙盒關閉離線匯出時的全部、
    超過上限被裁掉的、以及在最後一次觀測之後才移動並登出的。
    只能用它下這個結論：「清單裡有人在這塊地上」（正向證據）。
    絕對不能反過來說「清單裡沒人，所以這塊地沒有離線角色」。

  要證明某塊地「沒有任何角色」，唯一權威來源是存檔裡的 players.db
  （networkPlayers 表，玩家斷線時由引擎寫入當下座標）。那是 SQLite、遊戲的 Lua
  讀不到，只有停機中的外部工具讀得到。本目錄的檔案定位是「伺服器運行中的即時
  資訊」（現在誰在哪、要踢誰），不是停機後的完整清冊。

== 關於 steamId（client-reported, consistency-checked）==

這個欄位不是伺服器自己算出來的，是玩家的客戶端回報、再由伺服器做一致性檢查後
留下的值。原因是引擎沒給伺服器端拿到精確 Steam64 的路：伺服器只能拿到 Java long
經 Lua 轉換後的浮點值，Steam64 約 7.66e16，這個量級的浮點精度是 16，末一兩位會被
靜默捨去。會把 SteamID 字串化的引擎函式全都限定在客戶端。

伺服器做的檢查有兩道：格式（17 位、不小於 Steam 個人帳號區段起點），以及把回報值
與伺服器自己那個浮點值比對。亂填會被擋下，但同一個浮點值對應 15-16 個相鄰的
Steam64，而那些相鄰值多半也是真實存在的帳號，所以惡意客戶端仍可能挑其中一個通過
檢查。

因此：可以拿它做人類可讀的對照、稽核記錄、跨改名追蹤；**不可以**拿它做授權、
封鎖、所有權判定。需要權威值的話，停機後讀存檔 players.db 的 networkPlayers 表，
那裡的 steamid 是伺服器自己寫的字串欄位。

== 寫外部工具的人請照這幾條做 ==

  1. 整檔嚴格 JSON 解析。解析失敗就當檔案不存在並中止破壞性操作——外層物件到
     檔尾才閉合，任何被截斷的半個檔案都過不了嚴格解析。不要逐行流式取用。
  2. players 筆數要等於 count、其中 online:true 的筆數要等於 online。
     去重用 (name, idx)；出現重複就中止整份文件，不要靜默去重。
  3. 新鮮度 fail-closed：now - ts 超過 interval 的數倍（建議 3 倍）就當匯出已經
     停擺（沙盒被關、MOD 被移除、伺服器已停、或 MOD 拒寫），此時 online 只代表
     伺服器最後一刻的狀態。ts 比現在還新（超過約 60 秒的時鐘偏差）也要中止，
     否則未來時間戳會讓陳舊檔案永遠看起來新鮮。interval 不在 1-300 之內＝不可信。
  4. save 要等於你操作的存檔目錄名；offlineAuthority 要是 "observed-subset"。
  5. 離線清單不可反證（見上一節）。offlineSince 很新、或 offlineTruncated 是
     true，代表離線歷史更不完整，破壞性操作要更保守。
  6. 容忍檔案不存在（功能預設關閉，或剛開啟還沒到第一次週期）。

== 隱私 ==

開啟「匯出玩家座標檔」等於把玩家座標寫到磁碟上。只在確實要搭配外部工具時開啟；
一般伺服器不需要。
