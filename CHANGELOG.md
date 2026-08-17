# Changelog

## [42.20.2-0.15.0] - 2026-08-17

### 新增

- **玩家座標匯出（伺服器管理用，預設關閉）**：沙盒開啟後，伺服器（單機也適用）
  每 N 秒把「在線玩家的即時座標」與「離線玩家最後一次被觀測到的座標」寫成
  `Zomboid/Lua/MinidoracatMiniMap/players_存檔名.json`，與 `poi_blocks.json`
  同一目錄。用途是讓地圖區塊重置工具（pz-rewild）在清除一塊地之前知道
  「那裡現在有沒有人、有沒有人在裡面登出」，必要時先把人踢下線再動手——
  離線玩家的角色下次上線仍站在原地，重置到他身上會直接影響玩家。**在線清單是
  完整的（引擎權威）、離線清單只是本 MOD 觀測到的子集**——檔案裡帶
  `offlineSince`／`offlineIncluded`／`offlineTruncated` 三個欄位讓外部工具判斷
  可信度，契約明訂離線清單只能當「這裡有人」的正向證據，不能反證「這裡沒人」。
  三個沙盒選項：匯出開關（預設關）、匯出週期 1–300 秒（預設 5）、是否一併
  匯出離線玩家（預設開）。管理員面板改動即時生效，把週期改小也立刻生效。
  一般玩家不需要開；開啟後玩家座標會落地成檔案。
- **匯出檔帶 Steam64（`steamId`）**：每筆玩家帶 17 位 Steam64 字串，取不到時是空字串。
  這個欄位是**客戶端回報、伺服器做過一致性檢查**的值，不是伺服器權威值——引擎沒給
  伺服器端取得精確 Steam64 的路（見技術要點）。可用於對照、稽核、跨改名追蹤，
  **不可用於授權、封鎖、所有權判定**；要權威值請在停機後讀存檔 `players.db` 的
  `networkPlayers.steamid`。非 Steam 伺服器／客戶端一律是空字串。
- **`Lua/MinidoracatMiniMap/` 下自動放一份目錄說明**（`_README_CH.txt` /
  `_README_EN.txt`，分語系各一檔）：欄位表、兩份清單的證明力差異、`steamId` 的信任
  等級、外部工具義務摘要，讓看到那堆 JSON 的人不必翻 MOD 原始碼。只在檔案不存在時
  產生，之後不覆寫（可以在上面加自己的註記），刪掉下次啟動會補回。

> 技術要點：這件事引擎沒有替代路徑（42.20.2 反編譯核對）。Lua 讀不到
> `players.db`——`ServerPlayerDB`/`PlayerDB`/`PlayerDBHelper` 都沒 `setExposed`
> （LuaManager.java:1687-2712），且 `ServerPlayerDB` 只有依 username/steamid
> ＋playerIndex 的單筆 load/update、沒有列舉 API（ServerPlayerDB.java:216-227）；
> 唯一 Lua 入口 `getSaveInfo`（LuaManager.java:8068-8071 →
> PlayerDBHelper.java:134-165）只查 `localPlayers` 的 id/name/isDead，無座標。
> 也沒有「玩家斷線」事件（全 snapshot 無 `OnPlayerDisconnect`；`OnDisconnect`
> 只在客戶端且無玩家參數，LuaEventManager.java:653、GameClient.java:354-355），
> `GameServer.disconnect` 只寫 DB 不 triggerEvent（GameServer.java:2976-3034）
> ——所以「離線」只能由在線名單（`getOnlinePlayers()`，LuaManager.java:4454-4464
> → GameServer.java:3522-3541；單機退回 `getNumActivePlayers`/`getSpecificPlayer`，
> 分支慣例同原版 XpUpdate.lua:300-303）逐輪做差集推導。這個推導模型天生不完整
> （本 MOD 開始記錄前登出的角色永遠不在清單裡），所以檔案格式必須把不完整性寫
> 出來讓消費端 fail-closed，而不是假裝完整——三家獨立 review lane 都指向這一點。
> 唯一鍵是 `(name, idx)` 而非 name：`idx`＝`getPlayerNum()`
> （IsoPlayer.java:966-974，`@UsedFromLua`，原版 server 用例 ISPickDungCursor.lua:8），
> 伺服器端由 GameServer.java:2785 指派、與 `players.db` 的 `playerIndex` 同一身分；
> 同一帳號同機分屏可有多個角色分處兩地，只用 name 當鍵會把其中一個直接丟掉
> （對「保護玩家」是漏報，最危險的方向）。
> 節流掛 `OnTickEvenPaused`（LuaEventManager.java:594）不掛 `OnTick`：專用伺服器
> 在 `pauseEmpty`＋空服時 `paused` 為真（IngameState.java:1485-1486），`OnTick`
> 被 pause 閘門擋掉（:1489 判斷、:1532 呼叫、:1623 才 triggerEvent），而
> `OnTickEvenPaused` 在 :1316、pause 判斷之前——空服也必須繼續推進檔內時間戳，
> 否則工具無法區分「現在沒人」與「匯出已停擺」。專用伺服器觸發鏈
> GameServer.java:824 `IngameState statex` → :1001 `statex.update()`，主迴圈
> `LockFPS(10)`（:823）。真實時間用 `getTimestampMs()`（LuaManager.java:9267-9274）。
> 節流刻意存「上次寫檔時刻」而非「絕對到期時刻」，否則把週期從 300 秒改成 5 秒要等
> 舊間隔跑完才生效（離線測試 S4 釘住）；時鐘被往回調時視為到期，不會卡死。
> 檔名帶存檔名（`getWorld():getWorld()`＝`Core.gameSaveWorld`，
> IsoWorld.java:3192-3194，專用伺服器上是 serverName，:1792-1793）：`Zomboid/Lua`
> 是全域目錄、不隨存檔，同機輪流跑兩個世界時共用單一檔名會互相覆寫，也讓工具端
> 指錯檔時直接「檔案不存在」而不是讀進別的存檔的座標；檔名 token 只留 `%w - _`
> （點也轉底線——含 `..` 的路徑會被 `getFileWriter` 的 `hasRelativePath` 整個拒絕，
> LuaManager.java:6730、:8519-8522）。username 一律**無損** JSON 轉義（`\` `"` 依
> JSON 規則、控制字元寫成 `\u00xx`，對照表用 `string.char` 建、實機確認 33 筆）：
> 引擎允許的 username 字元集比直覺寬——primary 只擋 `" \ / . ' ? ; @ $ ,` 與 NUL、
> 長度 2-20（ServerWorldDatabase.java:763-785），**控制字元是合法的**，coop 分屏的
> secondary 更寬（只擋空字串與全服重名，ConnectCoopPacket.java:73-80）。所以絕不能
> 消毒或截斷：那會讓 `ab\nc` 與 `abc` 撞成同一個 registry 鍵、或讓名字轉換後變空而
> 被略過——少一個在線玩家就直接推翻「online 清單完整、可反證此處無人」這條核心
> 保證（第三條 review lane 抓出）。任何一個在線玩家無法無損寫出、或出現重複
> `(name, idx)` 時，本輪**整份拒寫**（讓舊檔因 ts 過期被工具擋下），不是略過那個人。
> 讀回時另用 JSON 字串文法驗證（含 `\uXXXX`）擋下裸引號，並用位數＋值域守衛擋下
> 「400 位數經 tonumber 變 inf、再被寫成 `"x":inf`」這種非法 JSON。排序用自備的迭代
> merge sort：家規禁 `table.sort`（Kahlua 是遞迴 quicksort、coroutine 堆疊上限 3000，
> **已排序輸入退化 O(n) 深度、數百筆即溢位**，見 scripts/verify_mod.py 檔頭）——而
> 本功能的輸入正好幾乎總是已排序（registry 讀回自按名稱排序的檔案）、上限 2000 筆，
> 用 table.sort 必炸；`table.concat` 一律傳 first/last，否則 Kahlua 會走 `table.len()`
> （TableLib.java:129-138）這個家規要避開的隱性長度依賴。沙盒關閉時檔案原地凍結、
> 不寫空文件：空清單會讓工具誤判「到處都沒人」而放行刪除，比陳舊檔案更危險——
> 新鮮度改由工具端比對檔內 `ts`／`interval`（含上界，防未來時間戳讓陳舊檔永遠
> 看起來新鮮），完整契約與外部工具義務寫在 `MinidoracatMiniMapPlayerExport.lua`
> 檔頭。週期不做每輪寫後讀回驗證（I/O 加倍且下輪就覆寫），改為每 5 分鐘**整份**讀回
> 重新解析並比對 ts/count/online——`LuaFileWriter` 走 `PrintWriter`
> （LuaManager.java:12751-12770），磁碟滿／唯讀時完全靜默、`pcall` 接不到；只驗第一行
> 不夠（header 落地、後續條目被截斷的 partial write 會被誤判成功）。
> 目錄說明檔是 `42/media/exportdoc/_README_<LANG>.txt` 靜態 UTF-8 檔，啟動時原封
> 不動複製出去，**不寫在 Lua 字面量裡**：Lua 原始檔由 `IndieFileLoader.getStreamReader`
> 載入，主路徑是 UTF-8（IndieFileLoader.java:22-24），但 fallback 到
> `Core.getMyDocumentFolder()/mods` 時用的是平台預設編碼（:25-27）——本機 linked-mod
> 走的就是 fallback，第一版把中文寫在 Lua 字串裡，實機寫出來整段是 U+FFFD 亂碼
> （`getFileWriter` 本身是 UTF-8，LuaManager.java:6753-6754，壞的是載入端）。改走
> 靜態檔後全程 UTF-8：`getModFileReader` 明確 `StandardCharsets.UTF_8`
> （LuaManager.java:6005，先找 versionDir 再找 commonDir）→ `getFileWriter` 寫出，
> 實機驗證與來源 byte-identical、管理員自己加的註記在重啟後完整保留（exists-only，
> 第二次啟動連來源檔都不讀）。守衛 `python scripts/tests/test_export_doc_assets.py`：
> 檢查 Lua 宣告的來源檔都存在、說明檔是合法 UTF-8／無 BOM／無 CRLF，以及
> **ExportReadme.lua 的非註解行不得含非 ASCII**（防有人又把中文塞回 Lua 字面量）。
> Steam64 只能由客戶端回報：`IsoPlayer.getSteamID()` 回 Java long
> （IsoPlayer.java:6412-6414），經 Kahlua 的 `NumberToLuaConverter` 一律轉成 Double
> （KahluaNumberConverter.java:141-142）——Steam64 約 7.66e16，該量級 double 的 ULP
> 是 16，末一兩位被靜默捨去，`tostring` 還會給科學記號；而引擎會把 SteamID 字串化的
> Lua 入口全都擋在客戶端（`getCurrentUserSteamID()` 條件含 `!GameServer.server`，
> LuaManager.java:9366-9372；`getSteamIDFromUsername()` 條件含 `GameClient.client`，
> :9470-9479；`SteamUtils` 未 setExposed；字串化的值只出現在
> ScoreboardUpdatePacket.steamIdsString，而那個 triggerEvent 也只在客戶端）。所以
> 客戶端用 `getCurrentUserSteamID()` 取精確字串、經 `sendClientCommand` 回報，伺服器
> 驗格式（17 位、≥ individual 區段起點）＋一致性（把回報字串 `tonumber` 後與自己的
> `getSteamID()` 比對，兩邊都是同一個 long 的 double 投影）。亂填會被擋下，但同一個
> double bucket 有 15-16 個相鄰 Steam64（實測任取一個 7.66e16 量級的值，其 bucket
> 涵蓋 15 個連續整數）且多半也是真帳號，所以只能標 client-reported,
> consistency-checked。回報協議：**只有驗證通過才回 ack**（失敗也 ack 會讓客戶端誤
> 以為完成而停手），ack 帶 slot、客戶端逐 slot 記帳（分屏時每個 slot 是獨立的
> (username, playerIndex) 身分）；客戶端掛 OnTick 輪詢而非 OnGameStart——後者在
> MP 連線就緒前（IngameState.java:761 vs :764-767、UpdateStuff():563）
> `sendClientCommand` 可能是 no-op。輪詢的每一條「未就緒」路徑（Steam 尚未初始化、
> IsoPlayer 還沒建立、onlineID 還是 -1）都只能等下一輪，**不能放棄**，否則功能會
> 靜默失效、而且在非 Steam 環境下與「本來就沒有 Steam ID」無法區分；真的放棄一定
> log。離線測試 `lua scripts/test_steamid_report.lua`（21 檢查，專門釘住這些窗口）。
> 主開關關掉再開時 `offlineSince` 會重設成當下：停用期間完全不觀測，那段時間登出的
> 角色不會進 registry，沿用舊起點等於宣稱空窗期的人也在清單裡。
> 離線測試 `lua scripts/test_player_export.lua`（198 檢查：黃金字串／無損轉義與文法
> 驗證邊界／數字位數與值域守衛／路徑消毒／讀回嚴格解析與拒絕（含重複鍵）／同名分屏
> 不塌縮並跨重啟保座標／排序正確性與穩定性含 2000 筆已排序輸入／節流與時鐘回跳／
> 離線差集／死亡剔除／writer 缺席／截斷檔／靜默寫入失敗與 partial write 抽驗／
> 不可表示名稱與重複鍵的整輪 abort）。真機驗證：隔離 `-cachedir` 的專用伺服器在
> `PauseEmpty=true`＋空服下 `ts` 每 ~5.05 秒前進、跨重啟讀回 registry（含負座標、
> 同名分屏與 `\u000a` 名稱的無損 round-trip）、輸出 `(name, idx)` 升序正確、
> 撕裂／裸引號檔被拒絕且 `offlineSince` 重設為當下。

### 修正

- **沙盒選項說明裡的輸出路徑被吃掉**：新加的說明裡用了角括號包住存檔名，tooltip 實際
  顯示成「輸出 .json（存檔名＝…」——整段輸出路徑憑空消失。原因是 tooltip 由 rich
  text 面板渲染，角括號會被當成標記，**而且同一個 token 裡角括號之前的文字會一起被
  丟棄**；中日文沒有空格，整句連成一個 token，所以殺傷範圍是整句而不只是那對角
  括號。現在移除說明裡所有角括號寫法（`players_存檔名.json`），並把四語說明的換行
  統一成實體換行、順手精簡過長段落。**翻譯改動要重啟遊戲才生效。**

> 技術要點：tooltip 由 ISToolTip 的 ISRichTextPanel 畫。`:459-486` 的 tokenizer 以
> 空格切，遇到同時含 `<` 與 `>` 的 token 就只取 `<...>` 內的標記字串丟給
> `processCommand`，其餘部分完全不寫進 `self.lines`——原版沙盒 tooltip 自己也在用
> rich text 標記（`<BHC>`、`<RGB:1,1,1>`），所以這是設計行為、不是 bug，寫文案時
> 就得避開角括號。單獨的 `>`（英文 `N > 0`）安全，因為條件要求 `<` 與 `>` 同時出現。
> 換行方面兩條沙盒 UI 路徑（新遊戲頁 SandboxOptions.lua:665-666、伺服器設定頁
> ServerSettingsScreen.lua:2522-2525）都會在交給控制項前做
> `tooltip:gsub("\\n", "\n")`，所以**字面 `\n` 本來就會正常換行**，既有 13 條與原版
> 那 35 條都沒問題；本次改用實體換行是因為它在兩條路徑都成立（gsub 找不到字面
> `\\n` 即 no-op，接著 ISRichTextPanel:445 把實體 LF 換成兩側帶空格的 `<LINE>`），
> 一個檔案裡只留一種寫法比較好維護。新增守衛
> `python scripts/tests/test_sandbox_tooltip_richtext.py`：把該 tokenizer 逐句移植
> 過來跑四語 160 個翻譯值，「含 `<`」「會被吞掉的文字」「連續換行」任一出現即 fail
> （negative test 能復現 `players_` 整段消失的現象）；字面 `\n` 也一併擋掉，理由是
> 寫法一致，不是它會壞。

- **兩張 MOD 地圖重疊時，小地圖影像顯示錯的那一張**（玩家回報：同時啟用
  Grapeseed 與 Greenleaf 時，Grapeseed 北緣兩個區塊在小地圖上「消失」、
  變成空草地，但遊戲世界與原版小地圖都是正確的城區）：兩張地圖真的共用
  3 格 cell（(24,42)(25,42)(26,42)，squares 6144,10752–6912,11008），引擎
  遇到這種衝突時以「地圖優先序最前者」勝出，而本 MOD 的影像疊層先前是照
  註冊清單字母序堆疊，跟引擎的勝出者無關——恰好把 Greenleaf 那片空草地
  疊在 Grapeseed 城區上面。現在影像疊層改為跟隨引擎的地圖優先序，
  地圖包登記的影像層一律顯示「遊戲實際載入」的那張地圖（第三方地圖 MOD 自附的
  約定檔名影像共用同一個檔名、在引擎裡是同一層，上下規則與此相反，維持原本的
  最上層位置、不納入這項一致性保證）。受影響的不只這一對：以本機安裝的
  69 個地圖 MOD（90 個地圖目錄）逐格比對 lotheader，共 82 對真的共用 cell
  （Kingsmouth North×Megurigaoka 12 格、Atlanta×BlackpineCounty 10 格、
  Grapeseed×Hartburg 6 格……），這些組合同時啟用時先前都可能顯示錯的那張。
  註：重疊 cell 本身是地圖 MOD 之間的衝突（遊戲選 MOD 畫面也會警告），
  兩張地圖不可能同時完整顯示；本修正保證的是「小地圖與你腳下的世界一致」，
  想換成另一張請用遊戲的地圖排序調整優先序

> 技術要點：引擎 `IsoMetaGrid.CreateStep1` 對 MapFiles 反序 `putAll`
> （IsoMetaGrid.java:1424-1428），故 `getLotDirectories()`／`getWorld():getMap()`
> 分號串的 index 0 最優先（原版註解 ISMapDefinitions.lua:25-28
> "highest priority (mods) to lowest priority (vanilla)"）；順序由
> MapGroups.setPriority／setOrder(ActiveMods.getMapOrder()) 決定。
> `getLoadedMapDirs` 原本把該串解析成集合（值 true）、順序被丟棄，現改存
> 1-based 優先序 index，mapDir 閘門改判 `~= nil`。新增純函式
> `orderByMapPriority`：只重排「對得上已載入目錄」的條目、並就地填回它們
> 原本的位置，pri 遞減（層間繪製正序、後建在上 ⇒ 最高優先最後建、畫最上；
> WorldMapRenderer.renderCellFeatures:933-938）。identity 解析鏈＝registry 的
> `mapDir` → zip basename → `getMapFoldersForMod(modID)` 反查
> （LuaManager.java:5390-5445）。反查是必要的：地圖包 91 筆有 3 筆 zip 名 ≠ 資料夾名
> （Atlanta - Safe Zone 目錄帶社群後綴、EchoCreek 目錄夾中文、Kardinal Raven Creek
> 的目錄其實叫 Raven Creek B42），其中 Atlanta 與 EdsAutoSalvageB42 真的共用 3 格
> cell，光靠 zip 名會讓它排不進優先序、繼續被壓在下面（codex review 抓出的正式
> 資料反例）。反查只在「該 mod 總共只提供一張地圖、且那張已載入」時成立：mod ID →
> 資料夾是多對一，引擎沒有 zip→資料夾的關聯，多張時拿「當下只載入一張」當識別會把
> 別張的 zip 標成它的 identity（codex review 第二輪抓出），一律放棄不猜、由 registry
> 明寫 `mapDir`；有 mod ID 卻仍解析不到的條目會 log 一行（正式資料應為 0 筆），基底與
> legacy 不進這條路徑、不會每次開圖刷屏。基底全圖與 legacy 兩者都以顯式
> `sortable = false` 固定位置（基底恆在最底、legacy 恆在最上），不靠「沒有 mapMod」
> 或「zip 名對不上目錄」的巧合——PZ 不禁止把地圖資料夾命名成 Muldraugh_KY 或
> minidoracat_minimap，隱含隔離在撞名時會破功（code review 抓出）；
> legacy 之所以要完全排除：全體共用同一檔名、去重後只有一層，層「內」同名多 zip
> 是反序迭代（先註冊者在上，WorldMapPyramidStyleLayer.java:46-51），與層間規則相反，
> 硬套會讓低優先者反而蓋住高優先者（codex review 抓出）。連帶把 canonical 檔名
> 定為 `registerMaps` 的保留名並拒收：同名兩份條目（一份來自 registerMaps、一份來自
> 自動掃描）會互搶同一圖層，前者被排序搬走、後者又被 layerId 去重丟掉，canonical
> 層可能落到其他地圖層下面（codex review 第四輪以 probe 重現）。
> 已知邊界（刻意不處理）：這套排序只管層間順序。同一個 zip 檔名的多個條目會被去重成
> 一層、層內是反序繪製（先掛在上），與層間規則相反——若同名條目來自不同路徑，層間
> 排序反而會讓低優先者畫在上面（codex review 第五輪以 probe 指出）。不修的理由：唯一
> 真實存在的同名多路徑情境是第三方自附影像那條 lane（多個 addon 共用約定檔名、各自
> bounds 對位，是刻意設計），而它已 `sortable = false`、順序等同本次修改前；兩個地圖
> 包提供同名 zip 時，兩份影像可能都合法且不重疊，「誰該在上」本來就沒有定義，去重會
> 直接弄丟一張圖。真要支援得按檔名分組反轉該組註冊序，等實際生態出現再做。
> 排序用插入排序（家規：Kahlua 遞迴 quicksort 會堆疊溢位，見 verify_mod.py）、
> 嚴格 `<` 才位移＝相等保留原序，n＝已啟用地圖數；只在掛載流程跑（開世界
> 地圖／小地圖 init／樣式重掛），不在每幀路徑上。`getWorld():getMap()` 拋例外時留下診斷
> （每次呼叫一行；框線重建與影像蒐集各呼叫一次，故一次 apply 會看到兩行。
> DEFAULT／空串是世界未 init 的正常路徑，維持靜默）。離線測試
> scripts/test_mapdir_gate.lua 補上回歸案例：雙向 map order、3 筆完整排序、同優先序
> 穩定性、重複目錄首見優先、明示 mapDir 不得 fallback、unknown 原位、反查含糊／
> 未載入／mod 不存在、log 靜默契約、正式 MAPS 的 sortable 契約、基底與 legacy 的
> 檔名撞名、registerMaps 拒收保留名，以及 collectPyramids 的整合案例（不手動塞
> mapDir，走完蒐集→identity 補齊→排序，含 Atlanta×Eds 雙向優先序、含糊時提示補
> mapDir、地圖包圖層關閉）。十個變異注入（升序、`<=`、寫回 1..n、忽略 sortable、
> 忘記傳旗標、忽略保留名、多地圖亂猜、丟失優先序 index…）全部被測試攔下

## [42.20.1-0.14.2] - 2026-08-14

### 變更

- **「資源點區塊用整棟範圍」改為預設開啟**（含既有玩家一次性套用）：
  0.14.0 引入時預設關（逐房間矩形），實際使用回饋是整棟範圍在導航上更
  直觀——一眼看出建築物邊界，搭配 0.14.1 的地標全縮放可見與描邊，區塊
  模式開箱即用。已在 0.14.0/0.14.1 存過選項的玩家也會在更新後首次進主
  選單時一次性套用新預設；之後偏好逐房間的玩家取消勾選即可、不再干預。
  其餘行為（圖標位置、顯示距離）不受影響
- **console／log 訊息全面改為英文**：遊戲 console 輸出走系統編碼（非
  UTF-8），中文 log 在 console.txt 與 DebugLog 裡是亂碼——排障時讀不了、
  玩家貼 log 回報也失去意義。既有診斷訊息全數改為英文（本版新增的訊息
  亦為英文）；遊戲內 UI 的多語翻譯不受影響

> 技術要點：預設值四點同步翻轉（addTickBox 註冊、POI provider 讀取與
> 簽章 fallback、統一視窗初始值）＋四語 tooltip 的「預設」標記換邊；
> 渲染測試補預設值契約案例（選項未設時帶 b 條目須畫整棟框）。一次性
> 遷移必要性：PZAPI save() 整檔全寫——玩家改過任何選項就把沒碰過的
> false 一併落檔、load 時存值優先於預設，只改註冊預設救不了既有安裝；
> 存檔的 false 幾乎全是「沒動過」而非刻意選擇（選項上線僅一天），比照
> MapImagery 0.10.1 前例翻轉＋marker 冪等（測試 W1-W6 六案例）。順序刻意
> 與前例相反：先寫 marker、以「存在性」讀回驗證落地，通過才翻值——marker
> 沒落地時翻值會在下次啟動重翻、覆蓋玩家事後的刻意關閉（codex review
> 反例；PrintWriter 吞 IO 例外，pcall 接不到，讀回是唯一證據）。寧可漏翻
> （fail closed 下次重試），不可重複干預。marker 自本次起集中放
> Lua/MinidoracatMiniMap/ 子資料夾（與 poi_blocks.json 同處）；既有兩個
> 根目錄 marker 屬歷史產物、原地不動。

## [42.20.1-0.14.1] - 2026-08-14

### 修正

- **一般民宅被標成超市／醫療／餐飲等資源點**（玩家回報 (6724,5447)、
  (10091,8257)）：官方地圖在住家裡放小型設施房間——客廳角落 2 格的雜貨儲藏
  櫃、二樓的家庭診間、廚房旁的肉品處理間——是為了讓那個角落刷出對應物資，
  先前把它當成整棟建築的身分，地圖上看到超市圖標、跑過去卻是民宅。現在住家
  裡佔比過小的設施房不再定義整棟身分，**23 棟民宅退場**；其中 (6065–6753,
  5321–5473) 一帶 6 棟假超市與 Louisville (13288–13610) 一帶 5 棟假服飾店
  是同批建築範本的群聚，在那兩區會連續踩到。另有 2 棟的主身分被小房間搶走
  的錯誤一併翻正（182 格的雜貨行原本標成服飾店、181 格的服飾店原本標成
  五金行）。真設施不受影響——軍事基地、療養院、醫院大樓、商場與公寓一樓的
  小型藥局／店面判定皆不變。資源點 1692→1669 筆
- **大型地標拉遠時從區塊模式消失**（實測回饋：March Ridge 地下軍事基地拉遠
  看不到、拉近又看不進整棟）：縮放 LOD 的「拉遠隱藏」檔位原是為了把已縮成
  色點的普通建築收掉，但 177 格寬的地堡在最遠縮放仍是明顯色塊、卻被一視
  同仁藏掉；且名稱要拉得很近才顯示，屆時整棟已塞不進視窗——大型地標從來
  沒有「整棟＋名稱」同框的縮放檔位。現比照伺服器區域的既有規則（最長邊
  超過 100 格不參與縮放 LOD）：20 筆地標級資源點（軍事基地、警局園區、
  商場等）改為任何縮放皆可見（含名稱），其餘資源點的縮放行為與效能結構
  不變。同場實測的第二發現：軍事的橄欖綠染色疊在地堡迷彩地形上幾乎看不
  出來、而暗色描邊原本只在拉最近時畫——「有染色卻看不出區域」；此類地標
  區塊的暗色描邊改為所有縮放皆畫，中距整棟同框時就有清楚邊界

> 技術要點：住宅門檻＝建物房間總面積 ≤800 格且臥室佔比 ≥10% 時，撤銷商店型
> 觸發房的免面積門檻豁免（觸發房佔比 <10% 則落給下一候選，與 accessory gate
> 同水位）。三條件缺一不可，逐項以全圖 9254 棟 counterfactual 定案：缺總面積
> 條件誤殺 14 棟機構型建物（臥室是宿舍不是民宅——地下軍事地堡、療養院、醫院
> 大樓）、缺臥室條件誤殺 7 棟店住混合真店面、缺佔比條件誤殺小坪數真店面。
> 800 格斷點取自實測落點（761 格民宅與 815 格真書店之間自然分離），非猜測。
> poi_blocks.json 隨之 count 1692→1669、2 筆條目的 cat 與 r 變動（b 不變）
> ——外部工具依契約驗 modversion 即可辨識，故本次必須 bump 版本號。

## [42.20.1-0.14.0] - 2026-08-14

### 新功能

- **資源點區塊「整棟範圍」模式**：新選項「資源點區塊用整棟範圍」（預設關）
  ——勾選後區塊改畫整棟建築外框（同棟跨樓層紀錄取聯集），不勾維持逐房間
  矩形；圖標錨點與顯示距離判定不受影響。ESC 選項頁的資源點選項同步獨立成
  「資源點（POI）」群組
- **伺服器區域獨立設定區**（裝 Zones addon 才出現）：統一視窗新增「伺服器
  區域」區——伺服器 zones.json 各區域可帶 `category` 欄位，視窗依實際資料
  動態生成逐類勾選（含全選／全不選；含逗號等不可逆編碼的類別名自動排除
  於 UI）；「區域名稱不受縮放限制」開關（預設開，拉遠也能找到區域位置）；
  範本生成的語言下拉與按鈕移入此區。**視窗開著時區域資料到貨自動刷新**
  ——按下生成或管理員 /reloadzones 後類別勾選即時長出來，不必重開視窗
- **區域縮放三檔 LOD**（provider schema 擴充 `lodRect`）：拉遠到中距只畫
  聯集外框色塊、再遠整組隱藏，拉近才畫逐矩形細節與名稱——大量建物尺度
  區域在全圖視野下的繪製成本大減；`haloAlpha`（暗色描邊）、`iconRect`
  （圖標錨點覆寫）、`distRects`（距離判定覆寫）一併開放。Zones addon
  0.4.0 起自動附掛 lodRect，舊 addon 傳統欄位照常運作
- **poi_blocks.json 匯出（外部工具契約）**：啟動時（單機進世界／伺服器啟動）
  自動把 1692 筆資源點（20 類、含整棟外框）寫到
  `Zomboid/Lua/MinidoracatMiniMap/poi_blocks.json`，供外部程式（如建築重置
  工具）讀取「地圖上實際顯示的資源點區塊」——與 Zones addon 的 zones.json
  同根目錄。payload 帶 modversion 新鮮度標記；寫後逐行讀回驗證，通過才記
  成功；工具端義務（整檔嚴格解析／count 對數／版本驗證／容忍不存在）
  文件化於檔頭與 README

### 變更

- **資源點區塊視覺改版：框線退場、暗色描邊上場**：區塊不再畫邊線，改為
  區塊底下墊一層外擴 2px 的暗色底（halo）——邊界對比不輸框線，每矩形的
  繪製呼叫從 4 次邊線＋1 次填色降為 2 次填色（實測回饋定案：純無框線
  難辨識，halo 是清晰度與效能的折衷）
- **全面效能優化**（實測 244 FPS 場景整輪驗證）：區域渲染對沒有填色／
  框線／圖標的資料整段跳過不空跑；殭屍／動物點位的座標轉換改用投影快取，
  大量圖標同時顯示時每幀成本大減；小地圖隱藏時整條渲染流程提早結束
  （導航抵達判定照常執行）；座標列顯示與資源點設定讀取加上快取與節流
- **需要遊戲 Build 42.20.1 以上**：poi_blocks.json 需要 `.json` 寫入
  （42.20.1 白名單解禁，同 Zones addon 0.3.0 的版本門檻），`versionMin`
  同步升起，避免 42.20.0 上功能靜默失效

### 修正

- **同一棟建築出現多重外框／多重圖標**：警察局等建築的地下室與地面層在
  原始地圖資料是兩筆獨立紀錄（外框差幾格），先前各自成點——疊框、雙圖標，
  跨類別時同棟還會掛兩個類別。改以「同名房間共享同座標矩形」判定同棟合併
  （全圖 27 組、1704→1692 筆），一棟恰好一個外框＋一個主身分
- **統一視窗長提示句溢出欄寬**：提示文字改逐 UTF-8 碼點貪婪斷行（拉丁字
  在空白處回退斷行），大字型與長句不再破版
- **區域類別篩選收口**：類別名含逗號或保留字時 CSV 停用清單無法可逆表示
  ——此類類別排除於勾選 UI（照常顯示區域）；provider 取類別失敗由靜默
  改為逐 owner log-once

> 技術要點：效能輪的機制——zone 三 pass 空跑閘為 hasFill/hasLine/hasIcon
> 表級旗標；熱路徑比較鏈取代 math.min/max（math.* 是 JavaFunction 跨界呼叫）；
> 仿射投影快取每幀 6 次 Java 取樣建 2×3 係數、其餘純 Lua 乘加；POI 重建簽章
> 15-tick 節流＋選項快取。同棟合併是兩段式分組——先精確 bbox 相等、再以 union-find 合併
> 「共享同名同座標房間矩形」的紀錄（rect 是世界座標實體地面，同名同座標
> ⟹ 同棟垂直堆疊；全 corpus 17 組全數為跨樓層對、60 對相鄰同層建築零誤併，
> 逐組不變式測試鎖住）。仿射投影快取每幀取樣 6 次建立 2×3 仿射係數，錨點
> 取視窗中心附近整數格壓 float32 精度誤差；LOD 門檻 scale<1.5 隱藏、<6 聯集
> 色塊、≥6 全細節。poi_blocks 匯出經四 lane review（Claude base／
> silent-failure／tests＋codex）：LuaFileWriter 走 PrintWriter 吞 IO 例外
> ——pcall 接不到磁碟錯誤，讀回驗證是唯一可靠完整性證據；離線測試 27 例
> （黃金字串＋真實資料煙霧＋整檔 stub 六情境 boundary）。

## [42.20.0-0.13.0] - 2026-08-07

### 新功能

- **資源點（POI）顯示距離**：新增沙盒選項，建築的資源點需其「顯示中的分類
  房間」最近點距玩家 N 格內才顯示（區塊／框線／名稱／圖標整棟一致顯隱）。
  建議 300＝約一個街區群，保留探索感；僅影響內建資源點，地圖包範圍框線
  不受影響
- **全域距離上限（沙盒）**：一鍵管住殭屍點位／動物／載具／安全屋／資源點
  五類距離，最優先生效——個別距離選項只能設得更嚴（兩者取較小），不能放寬
- **玩家自訂顯示距離**：統一設定視窗新增「顯示距離」區（ESC 選項頁有同組
  滑條），五類各一條、0＝不限。伺服器有設限時數值標直接顯示「你的設定／
  伺服器上限」（如 `200/300`），不必從滑條可拉範圍反推；兩值取較小生效——
  玩家只能收緊自己的視野，不能放寬伺服器限制

### 變更

- **沙盒選項重排**：同類相鄰——全域上限置頂並加【全域】標記、資源點移入
  顯示類別群、陣營分享等功能權限墊底。沙盒頁沒有標題或分隔線機制，整頁是
  依定義順序渲染的扁平清單，排序本身就是唯一的分組手段；值以選項名存取，
  重排不影響既有存檔（既有 MP 伺服器的 SandboxVars.lua 下次存檔會依新順序
  重寫，讀寫兩向皆安全）

### 修正

- **大字型下設定視窗滑條破版**：PZ 字型大小 26px 以上時，欄寬上限（不隨
  字型縮放的硬常數）會讓滑條軌道寬歸零甚至倒轉，而該值被當除數——0 會得
  nan 並經 setCurrentValue 寫進設定檔。軌道寬補下限；英文「資源點距離」
  標籤縮短——它原本是全視窗最寬標籤，而欄寬是共用值、會連坐壓縮八個區塊
  的每一列（日文在 33px/38px 的既有破版一併被下限擋住）

> 技術要點：距離合成收口於 sandboxDist／displayDist 兩層（伺服器個別值×
> 全域上限×玩家自訂取最小正值），五個消費端（殭屍取樣／動物／載具／安全屋
> ／POI）統一改走 displayDist。POI 距離逐 rects 判距，lodRect（分類房間
> 聯集 AABB、非建築 bbox——codex review 以實資料證明兩者可差數十格）僅作
> 下界快速排除；閘門置於螢幕裁切之前，故啟用距離閘反而比不啟用更省。滑條
> step=1：沙盒上限是任意整數，step>1 會讓存值被 ISSliderPanel 先進位再夾限，
> UI／存值／實效三方漂移。守衛測試新增 31 例（全域上限取小 7、displayDist
> 合成 9、滑條上限讓位 8、數值標格式 7）＋zone 距離閘 A8 六組，另有三道
> 原始碼層守衛（Client\* 命名四方對齊、unifiedSliderText cap 傳參、軌道寬
> 下限）——後兩者正是雙邊 review 抓到、helper 單測抓不到的缺口類型。

## [42.20.0-0.12.1] - 2026-08-06

### 修正

- **公寓誤標倉儲根治（POI 房間級重做）**：玩家回報 (10078,12631) 公寓大樓
  因 64 格住戶儲物間（佔房間面積 0.8%）被標倉儲。資料管線升級為逐房間
  幾何（pzmap poi v2 重擷 .lotheader 逐房座標），「附屬型」觸發房（倉儲／
  監獄／學校儲存家族、體育器材室等）面積佔比 <10% 不得冒充建築身分——
  對 0.12.0 基準 23 棟歸屬變更：14 棟噪音退場（7 公寓倉儲、5 場館戶外、
  監獄外圍場地棟等）、9 棟改判真實身分（Louisville 商場→藥局、保齡球館→
  餐飲、3 棟高中拿回學校圖標——school 並補 secondaryclassroom 等 3 鍵）。
  1720→1704 筆；同棟地下室/地面層雙紀錄先合併再分類，不再產生跨樓層雙圖標。

### 新功能

- **圖標錨定實際房間**：圖標從整棟外框中心移到主身分房間位置（商場藥局
  釘在場內藥局、公寓一樓店面釘在店面，約 1/3 條目受益）；區塊模式顯示
  主樓層房間平面（相鄰房間合併成塊、跨樓層不再疊色）
- **區塊縮放 LOD 三檔**：拉遠只留圖標、中距每棟一個純填色聯集框、拉近
  逐房間平面圖＋框線＋名稱——中/遠距的名稱洗版與框線雜訊即此治

### 效能

- 區塊全開曾在 Louisville 市中心掉到 8 FPS，三刀修復後中距檔實測 244：
  三 pass 世界座標視野預裁、仿射投影快取（每矩形 8 次 Kahlua→Java 投影
  歸零，只在視野中心採樣 3 點）、圖標同格去重疊（拉遠時互疊圖標只畫
  可見的那顆，繪製數砍 6~8 成；孤立圖標永不消失、拉近自動全部展開）
- POI 快取重建逐類預取類別勾選（~5k 次 ModOptions 查找→20 次）

> 技術要點：poi_raw.json v2（9254 棟 85,585 房間實例，與 v1 房名/外框
> 零差異）；POIData v3 格式 {cat, rn, r}（1704 筆 4764 矩形，256KB）；
> zone 契約新增 iconOnce/lodRect 選配欄（Zones addon 零波及）。守衛測試
> python 27 個＋zone render harness 全面擴充（兩層裁切分離驗證、LOD 檔位
> 邊界、去重疊三向、poi-convert 消費端契約、900 例隨機不變式）。雙邊
> （Claude＋codex）review 六輪，Blocking 全數修復；逐棟證據見
> MinidoracatMiniMapPOICategories.lua 檔頭查核區。

## [42.20.0-0.12.0] - 2026-08-06

### 新功能

- **資源點（POI）14 類→20 類、636→1720 筆**：新增電器行(52)／教堂(31)／
  農場(378)／工業(163)／零售(126)／餐飲(325) 六類，各配可辨識色＋單色/全彩
  圖標；既有類別補鍵——medical +8 鍵（+9 棟淨新增、2 棟含牙醫的複合樓自
  超市歸屬修正）、軍警 +19 鍵（現圖冪等防未來缺口）、戶外補 fishingstorage
  （+10 棟）；storage −10 主身分修正（咖啡店／工廠／郵局街區原掛倉儲圖標）。
  全部依 poi_raw.json 9254 棟逐鍵實算：否決會誤傷的 baggagesearch（Louisville
  商場變軍事）／killbox（豬屠宰場變監獄）／shed（99 棟中 83 棟是後院工具棚），
  armory 改歸警察（警局軍械室非軍事基地）。

### 效能

- **POI 圖標渲染視野預裁**：1720 筆逐幀投影前先以世界座標 AABB 早退——
  小地圖典型視野省 >99% 的 Kahlua→Java 投影呼叫、全圖拉遠最差僅 +0.2%；
  畫面逐位元不變（外接框超集形式證明＋差分/隨機/mutation 測試 0 誤殺）。
- POI 快取重建時逐類預取類別勾選（~5k 次 ModOptions 查找→20 次）。

> 技術要點：CATEGORY_PRIORITY 尾端順序逐棟實測定案（church<food 保自助餐教堂、
> electronics<retail 保百貨、industry<retail 工廠直售店 6:1、retail<food 餐飲
> 寄生 41 棟、storage 墊底）；四語翻譯新增 8 鍵並修 tooltip stale「15 類」；
> 三語 Steam 描述同步（6555/6965/7777 bytes 皆 <8000）。守衛測試 8→14
> （ORDER parity／圖標存在性／烘焙 byte-compare／優先級尾端鎖定／rooms 兩兩
> 互斥／鍵數快照）＋ test_zone_render.lua A5 視野預裁區塊（900 例隨機不變式）。
> 逐鍵查核與取捨依據見 MinidoracatMiniMapPOICategories.lua 檔頭；
> 雙邊（Claude＋codex）review-plus 三輪、發現全數落地。

## [42.20.0-0.11.0] - 2026-08-04

### 新功能

- **玩家座標顯示＋一鍵複製**：小地圖底部置中顯示目前 x, y, z（開關預設開，
  複製功能不受開關影響）；按鈕列新增 XY 鈕一鍵複製 `x,y,z` 到剪貼簿、右鍵
  選單「複製此處座標」複製指向位置（`x,y,0`）——格式與 `/teleportto` 直接
  相容，複製成功顯示 1.5 秒琥珀提示。
- **穿透模式（Ghost Mode）**：點擊／滾輪／右鍵點擊全部穿透小地圖直達遊戲
  世界、地圖本體半透明（不透明度滑條 10–90%，預設 40%、穿透中拉動即時生效）
  ＋外框變淡＋琥珀邊框——把地圖拉大當常駐畫面不擋操作、不擋視線（Discord
  玩家需求）。快捷鍵 `'`（引擎硬編碼／275 個 Workshop MOD／keysB42.ini／
  vanilla 四關空閒驗證）、浮動圖標右鍵（tooltip 標示左右鍵雙用途＋動態鍵名）
  或三處設定面切換，狀態跨重啟保留；分割畫面對所有玩家生效；防鎖死鏈三層
  （熱鍵→浮動圖標右鍵→ESC 選項頁）。
- **統一設定視窗預設全部收合**（原本每次開窗自動展開「圖層顯示」）。

> 技術要點：穿透＝事件 gate 明確 return false（右鍵 Java 收尾 nil 即消費）＋
> consume 旗標全組快照還原（防 stale picker：外框吃 mouse-move 會讓世界指向
> 不更新）；半透明＝分層壓暗（內容層×滑條值、被蓋住層歸零防疊層累積）＋底紙
> quad 歸零（mapAPI:setBackgroundRGBA，實測第一死點）＋未探索遮罩每幀重壓
> （WorldMapVisited singleton 與大地圖共用、退出還原）。三邊 review 修正
> 9 項。離線測試：`scripts/test_ghost_gate.lua`（G1-G6＋A1-A8）、
> `scripts/tests/test_translate_json.py`（四語 JSON 守衛）。

## [42.20.0-0.10.4] - 2026-08-03

### 加固

- **圖層自癒**：地圖影像圖層被其他 MOD 的樣式層壓下、或處於缺層／亂序
  狀態時，開圖即自動偵測並重掛回最上層；自癒時在 console.txt 寫入診斷行
  （含當時的最上層 id），「影像被藍色水體等向量圖形遮蓋」類回報可直接
  定位來源（源自地圖包許願串 #4 的 AnruisiTown 倉庫區回報）。
- **stale 圖層清掃**：MapPackLayers 關閉、或 MP 伺服器 Map= 收緊後，
  世界地圖不重建也會移除已不該顯示的舊圖層（既有缺口）。
- 建層中途失敗改為全拆重試、不留半掛狀態；同 zip 變體（Chinatown 兩版、
  legacy 約定名）圖層 id 顯式去重。

> Note：原版 42.20 樣式重建全是 clear() 起手（全有全無），純原版環境走不到
> 「壓下」狀態——本版屬防禦性加固＋診斷儀器，AnruisiTown 回報的實際成因待
> 玩家 console.txt 的自癒診斷行佐證。產品契約：本 MOD 圖層恆佔樣式最上層，
> 第三方晚掛的 style layer 會在覆蓋範圍內被壓下。
> 離線測試：`scripts/test_layer_tail.lua`（11 組決策矩陣＋5 組整合案例）。

## [42.20.0-0.10.3] - 2026-07-30

### 更新

- **內建資源點（POI）分類補洞：606→636 筆**：42.20 相容性稽核發現分類表涵蓋
  不一致——police/fire/gas/grocery/sport/army 的 storage 變體都收了，唯
  medical/pharmacy/school/prison/outdoor 系缺漏，約 30 棟高價值建築在地圖上
  隱形。補齊 15 個 room key：medicalstorage/hospitalstorage/pharmacystorage/
  campingstorage/schoolstorage/schoolgymstorage/policelocker/policearchive/
  prisonstorage/prisonlaundry/gymstorage/universitystorage（Distributions
  頂層 loot key）＋gunstorage/bookstorage/universityclassroom（非 loot key，
  依 bunker「位置存在」前例收錄，含大學園區三棟大樓）。部分建築主身分隨之
  修正（如藥局倉庫建築 grocery→pharmacy、大學園區 medical→school），屬
  語意修正非資料遺失。ranger 護林站（42.20 新圖 1 棟）維持併入 medical 顯示
  （全圖僅 1 棟，獨立類別不划算，查核註記已記錄）。
- 雙邊 review-plus（Claude／codex 獨立 lane）皆 COMMENT 無 blocking；
  gen 決定性重跑一致、離線測試全綠。

## [42.20.0-0.10.2] - 2026-07-29

### 更新

- **遊戲 42.20 基底全圖重渲**：42.20 更新主世界 950 個 cell（Muldraugh／
  Rosewood／Riverside／West Point 城區）並新增 JUMBOXL/JUMBOXXL 巨樹
  （JumboTreesBigs2x.pack）；以完成 42.20 修正（巨樹 pack 補載＋anchor 分層＋
  畫布邊界）的 MapRendering 重渲 `Muldraugh_KY.pyramid.zip`（bounds 不變
  0 0 19968 16128，Lua 掛載鏈零改動）。
- **POI 資料 42.20 重生**：`pzmap poi` 重擷 poi_raw.json（建築 8541→9254 棟）
  → `gen_poi_data.py` 重生 POIData（499→606 筆，14 類全數有值，luac -p 通過）。
- **Lua 相容性查證（42.19→42.20 反編譯逐檔 diff）**：掛載鏈依賴的
  WorldMap／ImagePyramid／WorldMapImages／MapDefinitions／UIWorldMapV1-V3
  位元組相同；被 hook 的原版 `ISWorldMap`／`ISMiniMap` 等 Maps/ Lua 42.20
  未更動——功能面免改，僅版本元資料 bump（modversion=42.20.0-0.10.2、
  versionMin=42.20.0、三語描述 42.20.0+、workshop.txt 重生成）。

## [42.19.0-0.10.1] - 2026-07-21

### 修正

- **緊急修復：0.10.0 圖片化地圖全面失效（退回原版向量樣式）**：mapDir 逐圖閘門的
  `getLoadedMapDirs` 使用了 PZ Kahlua 未註冊的全域 `next()`，只要
  `getWorld():getMap()` 回傳有效清單（MP 必定、單機多數）即拋
  「Object tried to call nil」，pyramid 掛載鏈中斷、全部退回原版地圖
  （Steam 玩家 gwinnblayd 與自營伺服器實測回報）。42.19.0 反編譯查證：
  Kahlua BaseLib 僅註冊 18 個全域，`next`/`assert` 皆不存在。兩處 `next()`
  （`getLoadedMapDirs` 與 `navShareGateTick` 的隱性地雷——伺服器關閉
  AllowNavShare 時會每 tick 炸）改為 `pairs` 探測空表，語意等價、
  fail-open 路徑不變。
- **一次性重新開啟「圖片化地圖」總開關**：故障期間部分玩家排查時可能把總開關
  關掉，修復後仍看原版樣式且不知要開回。比照快捷鍵遷移：主選單一次性強制設回
  預設 true＋寫 marker（Zomboid/Lua/MinidoracatMiniMap_imageryForcedV1.txt）；
  之後玩家再關閉即屬刻意選擇，永不再干預。離線測試 V1-V5。

### 內部

- **Kahlua 缺失全域守衛測試**：新增 `scripts/tests/test_kahlua_globals.py`，掃描
  全 MOD 執行期 Lua 的 `next(`/`assert(` 裸呼叫——這類「實機才炸、離線測試
  （標準 Lua）全綠」的雷改由靜態守衛在離線階段攔下。

## [42.19.0-0.10.0] - 2026-07-20

### 修正

- **一 mod 多地圖的逐圖閘門（`mapDir`）**：registerMaps 條目新增選配 `mapDir`
  （地圖目錄名）。指定時除 mod ID 啟用外，還須該目錄實際載入世界才掛圖/畫框——
  修 MP 伺服器只在 `Map=` 挑部分 SecretZ 據點時，未載入據點仍被畫出的誤顯示
  （玩家 baker 回報）。判定源＝`getWorld():getMap()`（Java `Core.gameMap`）：
  單機＝MapGroups 串起的全部啟用 MOD 目錄（行為不變）、MP 客戶端＝伺服器
  `Map=` 清單（世界 init 時 IsoMetaGrid.getLotDirectories 回填；42.19 反編譯查證）。
  拿不到清單＝fail-open 回退純 mod ID 閘門；空字串 mapDir 視同未指定（單點中和，
  不整條目拒收）。離線回歸測試 `scripts/test_mapdir_gate.lua`（串列解析/修剪/
  單目錄/fail-open 矩陣＋rebuildMapOverlays 整合過濾案例）。

## [42.19.0-0.9.0] - 2026-07-20

### 新增

- **浮動開關圖標**：常駐畫面的小圖標（預設開），點擊直接開關小地圖——純滑鼠玩家
  不再依賴快捷鍵。可拖曳擺放（4px 位移門檻區分點擊/拖曳），位置自動記憶
  （ModOptions FloatIconPos "x,y"，同 CustomSize 先例可手動清空還原）；獨立於
  小地圖視窗、關圖後仍在；hover 顯示提示「開關小地圖（快捷鍵：X）」——動態讀
  當前綁定（含修飾鍵前綴），改鍵即時反映；統一設定視窗「外觀」區與 ESC 選項頁皆可開關；
  材質（media/ui/minimap_toggle.png，64x64）缺漏時 nil-safe 以「M」字替代；
  回主選單自動隱藏、進遊戲自動恢復。
- **快捷鍵自動遷移**：首次進遊戲時若綁定仍是舊預設「無修飾鍵的 HOME」則自動改為
  /（斜線）並寫回 keysB42.ini（走 MainOptions.keyText → saveKeys 正規路徑；帶修飾鍵或
  已改鍵＝玩家刻意設定，不動）。marker 檔 Zomboid/Lua/
  MinidoracatMiniMap_keyMigratedV1.txt 記錄已處理，玩家事後刻意改回 HOME 不再干預。
- **圖片化地圖總開關**（統一視窗「圖層顯示」首列＋ESC 選項頁＋世界地圖（M）
  選項面板，三面同源，預設開）：關閉後
  不掛任何 pyramid 圖層，小地圖與世界地圖回到原版向量樣式，圖標/資源點/殭屍點位
  等其他功能全部照常。切換即時生效：世界地圖逐 id 卸載/補掛本 MOD 樣式圖層
  （外科手術式——不走 Reapply Style，避免 styleAPI:clear 誤刪其他 MOD 的圖層）、
  小地圖 Recreate 重建；applyMiniMapPyramids 為所有掛載路徑唯一入口＝單點閘門，
  框線資料重建置於閘門之前（關閉圖片化時 MOD 地圖框線照常）。無小地圖
  （沙盒 AllowMiniMap 關閉）時仍可切換世界地圖；apply 決策抽為純函式
  computeApplyPlan＋離線矩陣測試 P1-P9。
- **-debug 渲染除錯警告**：debug 模式下偵測到「世界渲染已被切至舊管線
  （PerformanceSettings.fboRenderChunk=false，多半是誤按 HOME）」或「開關綁定
  仍是 HOME」時，小地圖頂部顯示橘色警告條（前者優先、提示再按 HOME 復原）；
  浮動圖標 tooltip 同步附警告行，並常態多顯示一行「目前渲染管線：chunk-FBO（新版）
  ／舊版逐 tile」讓 debug 使用者隨時可查。非 debug 環境一個布林判斷即返回、零成本。
  fboRenderChunk 為 exposed class 的 public static 欄位（同 Keyboard.KEY_* 讀法），
  以 pcall 防未來版本移除。Steam 描述同步把 -debug/HOME 注意事項獨立成醒目區塊。

- **圖標大小/透明度全面滑條化**：殭屍點、動物圖標、載具圖標、資源點圖標四類
  各自獨立「大小(px)」與「透明度(%)」滑條，統一設定視窗（內嵌 ISSliderPanel）與
  ESC 選項頁（PZAPI 原生 addSlider）雙面可調；拖動即時預覽（繪製端每幀讀值）、
  放開滑鼠才落盤（避免拖曳中高頻檔案 IO）。動物與載具大小自此拆分（原共用一顆
  三檔下拉）；資源點圖標大小（原固定 18px，作用於所有 zone 圖標）與四類透明度
  （原寫死常數）首次開放。舊三檔下拉存值於主選單一次性自動換算為對應像素
  （動物依當時風格選映射表、載具以舊共用值播種；離線測試 M1-M5 覆蓋）。
  世界地圖（M）圖標沿用共用設定、自動跟隨。

### 變更

- **統一設定視窗區塊標題一致化**：「殭屍點位」→「殭屍圖標」、「資源點」→
  「資源點圖標」，與既有「動物圖標／載具圖標／世界地圖圖標」命名對齊（四語系
  同步；Steam 描述引用的小節名一併更新）。
- **小地圖預設快捷鍵 HOME → /（斜線）**：HOME 在 -debug 模式下是引擎隱藏熱鍵
  （IsoCell.render 按鍵切換 PerformanceSettings.fboRenderChunk，整個世界渲染
  退回舊版逐 tile 路徑——本機實測 FPS 約減半 244→124、地面積雪外觀隨渲染路徑
  改變），與小地圖開關同鍵齊發，讓 debug 環境的使用者誤以為小地圖吃 FPS。
  /（斜線，M 鍵右方——大地圖 M、小地圖 /）於原版 keyBinding.lua 未綁定（含裸數字
  鍵碼掃描）、引擎 Java 層無硬編碼、無文字框編輯副作用（文字輸入期間引擎本就不
  派送綁定）、本機 213 個 Workshop MOD 與 keysB42.ini 全 56 綁定掃描空閒、實體
  位置跨鍵盤佈局穩定、顯示名稱「/」無歧義。選鍵否決紀錄：K 撞原版「Display FPS」
  （keyBinding.lua:199 以裸數字 37 註冊，掃 KEY_* 常數抓不到）；0 的顯示字元在
  UI 字型下似字母 o；F7/F8/F9 是 debug 裸鍵編輯器（載具/世界地圖/接縫，
  IngameState.java:1398/1424/1431）、F12 撞 Steam 截圖；9 被 Bandits Week One
  事件鍵使用；N 撞 StartVehicleEngine。注意：綁定會持久化寫入 keysB42.ini、
  既存值蓋過新預設
  （MainOptions.loadKeys 於 ini 讀入後覆寫）——存量安裝由上方「快捷鍵自動遷移」接手。

## [42.19.0-0.8.0] - 2026-07-18

### 新增

- **內建資源點（POI）**：主 MOD 內建原版地圖的 499 筆資源點、14 類（軍事、警察、槍店、
  醫療、藥局、消防、圖書／書店、學校、超市、加油站、五金／修車、戶外／打獵、監獄、
  倉儲，各配可辨識色），裝本體即見。以內部 zone provider 註冊，預設「圖標模式」
  （每點於中心畫染色剪影圖標、不鋪標籤），可勾「彩色資源點圖標」改用全彩圖；另有
  「顯示資源點區塊」選配（半透明色塊＋名稱）。統一設定視窗新增「資源點」收合小節：
  母開關＋彩色切換＋14 類 3 欄勾選格（列首帶類別小圖）＋全選／全不選；齒輪面板同步
  提供「顯示資源點」快速開關。同建物含多類別房間時以主類別去重（如警局內含牢房不再
  疊監獄圖標）；分類收錄原版 room 別名（medclinic／elementaryhall，
  SuburbsDistributions.lua:162/:177）。圖標素材缺漏時 nil-safe 跳過，不影響區塊模式。
  四語翻譯齊備。
- **zone schema `icon` 欄位與 per-provider 開關**：zone 可帶 `icon = { tex, r, g, b }`
  （每 rect 中心投影畫染色圖標，與框線同層）；`registerZoneProvider` 新增選配第三參
  `optionLabelKey`，給了就由本 MOD 於統一視窗動態追加一顆 per-provider 母開關
  （關＝渲染時整個跳過該 provider）。
- **registerZoneAction API**：addon 可註冊設定頁動作列（`[下拉選單]+[按鈕]` 一列，
  spec 帶 labelKey／tooltipKey／options／onTrigger），渲染於圖層區伺服器區域開關之後
  ——Zones addon 的「生成區域範本」按鈕即以此實作。無註冊時零列（dormant）。

### 修復

- **統一設定視窗捲動與排版**（三項疊加根因，實機探針逐一驗證）：
  1. `setScrollChildren(true)` 在 panel 的 javaObject 尚未建立時為靜默 no-op
     （ISUIElement.lua:1647 直接 return），子元件渲染從不吃捲動位移——改為先
     `instantiate()` 再設定；
  2. 自畫標題／圖標的手動 `+getYScroll` 移除——java 端 DrawText／DrawTexture 已自加
     yScroll（UIElement.java:190-194），再加一次＝雙倍速錯位；
  3. vanilla `keepOnScreen` 螢幕夾制誤傷內容座標子元件：`addOption→setHeight`
     （ISTickBox.lua:234）會把尚無 parent 的 tickbox y 夾到「螢幕高−元件高」
     （ISUIElement.lua:245-251；getKeepOnScreen 預設 `not self.parent`），全展開時
     超過一屏的勾選全疊在同一列——建構前顯式關閉 keepOnScreen。
  修畢後全展開內容可完整捲動到底、逐列可點、文字不重疊。

### 變更

- 統一設定視窗所有開關／下拉即時套用並持久化（等同 ESC MOD 選項頁儲存，無需另開選單）。

## [42.19.0-0.7.0] - 2026-07-17

### 新增

- **Zone 渲染 API**：新增 `MinidoracatMiniMapAPI.registerZoneProvider(ownerModId, providerFn)`
  與 `MinidoracatMiniMapAPI.zoneApiVersion = 1`，讓區域圖層 addon（家族第四個 MOD
  MinidoracatMiniMapZonesFor42）把矩形區域資料交給本 MOD 渲染。本 MOD 每幀呼叫 provider
  取回已翻譯、已正規化的 zone 陣列，在小地圖與世界地圖以半透明色塊填色、框線描邊並置中標名。
  provider 每幀回傳快取表、繪製端只讀不改；provider 拋錯以 pcall 攔截並首次記 log，
  不影響地圖其餘繪製。
- **「顯示區域圖層」總開關**：偵測到有 zone provider 註冊時，於 ESC 選項頁、統一設定視窗
  圖層區、齒輪面板三處動態追加開關（預設開）。關閉即整層不繪製，且不觸發 provider 重建。
- **MOD 地圖框線透明度（MapBoundsAlpha）**：新下拉三檔（不透明／半透明／隱約，
  沿用小地圖不透明度的翻譯鍵與倍率 1.0/0.5/0.15），同時作用於框線與名稱標籤；
  預設不透明＝與先前外觀完全相同。ESC 選項頁與統一設定視窗外觀區同步提供，
  隨地圖包安裝動態出現（同 MapBoundsColor）。
  未安裝區域圖層 addon 時整條管線休眠、零成本。四語翻譯（繁中／簡中／英／日）齊備。

### 變更

- 更正 `MinidoracatMiniMapServer.lua` 開頭「SP 下 OnClientCommand 不觸發」的舊註解：
  B42 單機走 spnetwork loopback，`OnClientCommand` 在單機同樣觸發。

## [42.19.0-0.6.0] - 2026-07-15

### 新增

- 新增 `MinidoracatMiniMapAPI.registerAnimalGroup(ownerModId, group, labelKey, symbolPath, itemPath)`，
  讓獨立相容包把第三方 `IsoAnimal` 群組加入既有物種篩選，並可選擇提供自己的符號與彩圖；
  未提供素材時使用原版爪印安全備援，不接受 callback，也不接管上游 MOD 自己的地圖標記。

## [42.19.0-0.5.0] - 2026-07-15

### 新增

- **伺服器顯示距離限制**：殭屍點位、動物圖標、載具圖標與安全屋框線可分別設定
  顯示距離；`0` 代表不限制，正數代表只顯示玩家 N 格內的項目。採二維距離、不計
  樓層，管理員按「套用」後立即生效。

### 變更

- **牲畜圖標可見性改為四檔**：全部顯示／隱藏其他安全屋內的牲畜（預設）／僅顯示
  我方安全屋內的牲畜／全部隱藏。安全屋歸屬包含屋主與受邀成員，依動物目前位置判定；
  野生動物不受影響。這是誠實客戶端的顯示政策，不是動物所有權或防作弊機制。
- **升級注意**：舊版「顯示其他玩家的牲畜」開啟值不會自動遷移；更新後預設為
  「隱藏其他安全屋內的牲畜」。原本要全部顯示的伺服器管理員需手動改選「全部顯示」。

### 修復

- **陣營分享關閉後仍殘留既有目標**：管理員停用陣營分享時，已收到的共享目標現在
  立即隱藏並清除；停用期間延遲抵達的舊封包不會在重新開啟後復活。
- **PVP 距離閘門殘留舊點**：距離值或玩家物件狀態改變時立即淘汰取樣快取；距離
  限制啟用但暫時無法取得玩家時採 fail-closed，不保留舊殭屍、動物或載具點位。
- **統一設定視窗摘要不同步**：收合標題改為即時計算；世界地圖圖標區顯示已開啟的
  類別數量，不必重新收合或開啟視窗才更新。
- **多語沙盒提示過長**：繁中、簡中、英文與日文 tooltip 加入語意換行，避免橫跨
  大半個畫面。

## [42.19.0-0.4.0] - 2026-07-14

### 新增

- **世界地圖圖標**：殭屍點位／野生動物／畜養動物／載具圖標登上世界地圖（M）——
  四個獨立開關（統一設定視窗新增「世界地圖圖標」區段，與原版世界地圖選項分開
  不混淆），風格、顏色、大小與物種／類別篩選跟隨小地圖設定；受同組沙盒管理
  選項控管。
- **世界地圖爪印入口**：世界地圖右上按鈕列新增爪印按鈕，直接開啟統一設定視窗
  （不必先開小地圖）。

### 修復

- **世界地圖 MOD 地圖圖像會中途消失且不復原**：原版三條路徑（色盲圖案設定
  同步偵測、debug「Reapply Style」、地形圖片切回）會重建世界地圖樣式，把本 MOD
  的圖像圖層洗掉——世界地圖是單例、原掛載點只在建立時跑一次，洗掉後不重啟
  遊戲不會恢復。現在開圖時與樣式重建後都自動補掛（冪等），玩家零操作。

## [42.19.0-0.3.0] - 2026-07-14

### 新增

- **動物圖標（預設關）**：小地圖即時顯示附近動物——野生／畜養獨立開關；9 物種
  個別篩選（牛/羊/豬/鹿/雞/火雞/兔/浣熊/鼠類）；兩種圖標風格（原版地圖符號染色／
  物品彩圖）；大小三檔；野生・畜養顏色可自訂（色盲友善 8 色，Okabe-Ito 為底）。
  全部使用遊戲內建素材，零自帶圖檔。
- **載具圖標（預設關）**：方向盤符號顯示可視範圍內載具（內建無車形地圖圖示，
  方向盤為最接近的原版符號）；一般／重型／性能（mechanicType 1/2/3）＋特勤
  （警燈車）類別篩選；顏色可自訂。
- **統一設定視窗**：齒輪鈕改開新視窗，整併原設定視窗與圖層面板注入項——
  雙欄五區塊（圖層顯示／殭屍點位／動物圖標／載具圖標／外觀與行為）可收合、
  標題列現況摘要、全部展開／收合、各語系實測字寬自適應版面、內容捲動
  （高度不超出螢幕）、沙盒停用標示。引擎原生三項（等軸測／符號／遠端符號）
  移入圖層區；「=」圖層面板鈕退役（按鈕列 6 顆）。
- **沙盒管理選項 ×3**：允許動物圖標（預設開）、顯示其他玩家的牲畜（他人安全屋
  內的牲畜可見性，預設關——基地隱私）、允許載具圖標（預設開）。
- **自由查看回中提示**（導航軟體同款模式）：拖離玩家後，小地圖底部浮出
  「點擊地圖回到玩家」琥珀提示、C 鈕同步高亮——回中即消失。

### 修復

- **圖層面板勾選被設定套用蓋回**（玩家回報）：殭屍熱度等引擎選項的面板勾選
  現會回寫 MOD 選項——任何設定調整不再把勾選強制改回；MP 沙盒壓制解除時
  也改恢復成玩家自己的偏好。
- **改尺寸／重建不再丟失**等軸測、符號、遠端符號設定（重建前快照回寫）。
- **分割畫面**：設定視窗記住開啟它的玩家，引擎選項讀寫與視窗夾位不再固定 player 0。
- 安全屋邊界判定照原版半開區間（東／南界外一格的牲畜不再被誤隱藏）；
  空篩選欄位經 PZAPI 存讀變 "nil" 髒字串（改用 sentinel）；
  材質快取不再把暫時載入失敗變成整場消失。

## [42.19.0-0.2.0] - 2026-07-13

### 新增

- **地圖包註冊 API**：`MinidoracatMiniMapAPI.registerMaps(ownerModId, entries)`——
  地圖包 addon（如 MinidoracatMiniMapModMapsFor42，`require=` 本 MOD）向本 MOD 註冊
  地圖清單（zip/mapMod/bounds/nameKey），zip 放地圖包自己的 `media/minimap/`，
  依對應地圖 MOD 啟用狀態自動掛載。首批三張地圖已移往地圖包 addon 專案。
- **MOD 地圖框線＋名稱顯示（MapBounds）**：對已註冊且啟用的地圖 MOD，在角落
  小地圖與世界地圖（M）以框線標出範圍、中心顯示地圖名稱（走 UI.json 翻譯，
  缺譯退 mod ID）。
- **地圖包專屬選項（裝了地圖包才出現，OnGameBoot 依註冊狀態動態追加）**：
  「顯示 MOD 地圖區塊」（掛不掛地圖包圖像，改動即重建小地圖）、「顯示 MOD 地圖
  框線」、「MOD 地圖框線顏色」（預設綠，另有青/黃/紫/白）——ESC 選項頁、齒輪面板、
  設定視窗三處同步。

### 變更

- **pyramid 架構改為 manifest 驅動集合包**：本 MOD `media/minimap/` 集中放各地圖 zip
  （檔名＝地圖原名，pzmap Studio 預設輸出名免改名），`MAPS` manifest 宣告對應的地圖
  mod ID——基底圖（`Muldraugh_KY.pyramid.zip`）永遠掛載，地圖 MOD 的圖僅該 MOD 啟用
  才掛載；每個檔名動態建一個 Pyramid 樣式層。第三方 addon 的
  `minidoracat_minimap.pyramid.zip` 同名約定保留為相容路徑（零 Lua 不變）。

## [42.19.0-0.1.0] - 2026-07-11

### 新增

- 專案初始版本（v1 最小可用）。
- `MinidoracatMiniMap.lua`：hook `ISWorldMap:initDataAndStyle`，掃描啟用 MOD 的
  `media/minimap/minidoracat_minimap.pyramid.zip` 並以 `addImagePyramid` 掛載，
  疊加單一 Pyramid 樣式層（不清空原版樣式），全程 pcall 防禦。
- `scripts/build_pyramids.ps1`：呼叫 pzmap `render-minimap` 產生基底 zip。
- `link_workshop.bat` / `PZ_Test.bat`：本地 no-steam 測試流程（沿用 MinidoracatLangFor42 腳本架構）。
