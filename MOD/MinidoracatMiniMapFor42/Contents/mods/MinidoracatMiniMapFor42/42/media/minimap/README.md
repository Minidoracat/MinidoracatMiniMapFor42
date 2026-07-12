# media/minimap/ — 基底 pyramid zip

本 MOD 只放**基底全圖**（檔名＝地圖原名，pzmap Studio 預設輸出名）：

```
Muldraugh_KY.pyramid.zip      ← 基底全圖（B42 主世界），永遠掛載
```

- 產生方式：專案根目錄 `scripts/build_pyramids.ps1`（呼叫 pzmap render-minimap）。
- **地圖 MOD 的圖不放這裡**——走「地圖包 addon」：獨立 MOD（`require=` 本 MOD）
  在自己的 `media/minimap/` 放 zip、client lua 呼叫
  `MinidoracatMiniMapAPI.registerMaps(自身 mod ID, 條目清單)` 註冊
  （官方地圖包專案：`D:\github\MinidoracatMiniMapModMapsFor42`）。
- 第三方地圖 MOD 想「自帶」minimap 支援：把渲染圖命名為約定檔名
  `minidoracat_minimap.pyramid.zip` 放進**該 MOD 自己的** `media/minimap/`，
  零 Lua，本 MOD 會自動掃描掛載（相容路徑，檔名尾綴匹配、bounds 自動對位）。
- `*.pyramid.zip` 為渲染產物，**不進版控**（見專案 .gitignore）。
