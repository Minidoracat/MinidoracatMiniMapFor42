# Changelog

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
