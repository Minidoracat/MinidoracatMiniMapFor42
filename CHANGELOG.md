# Changelog

## [未發布]

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
