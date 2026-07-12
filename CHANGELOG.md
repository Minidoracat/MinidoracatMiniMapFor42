# Changelog

## [未發布]

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
  框線」、「MOD 地圖框線顏色」（青/黃/紫/白/綠）——ESC 選項頁、齒輪面板、
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
