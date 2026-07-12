# Changelog

## [未發布]

### 新增

- **MOD 地圖框線＋名稱顯示（MapBounds，預設開）**：對 manifest 裡已啟用的地圖 MOD，
  在角落小地圖與世界地圖（M）以青色框線標出範圍、中心顯示地圖名稱（走 UI.json
  翻譯，缺譯退 mod ID）。ESC 選項與齒輪面板皆可開關。
- **首批地圖 MOD 集合**：Muldraugh 消防局（beek_muldraugh_firedept，基底範圍內
  overlay）、Estate 39（獨立區域）、唐人街擴張區（Chinatown Expansion B42 version，
  Muldraugh 北緣、依賴 6 個 tile pack）——`MAPS` manifest 各帶 bounds 與翻譯鍵。

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
