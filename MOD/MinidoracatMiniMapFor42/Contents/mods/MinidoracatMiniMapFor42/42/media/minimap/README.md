# media/minimap/ — pyramid zip 集合目錄

此目錄集中放置本 MOD 支援的各地圖 pyramid zip，**檔名＝地圖原名**
（即 pzmap Studio「遊戲內小地圖」模式的預設輸出名，渲染完直接丟進來免改名）：

```
Muldraugh_KY.pyramid.zip      ← 基底全圖（B42 主世界），永遠掛載
RavenCreek.pyramid.zip        ← 範例：地圖 MOD 的圖，該 MOD 啟用才掛載
```

- **哪顆 zip 對應哪個地圖 MOD，由 `MinidoracatMiniMap.lua` 開頭的 `MAPS`
  manifest 宣告**；新增支援地圖＝放 zip ＋ manifest 加一行 `{ zip = "...", mapMod = "<該地圖 mod ID>" }`。
- 產生方式：基底跑專案根目錄 `scripts/build_pyramids.ps1`（呼叫 pzmap render-minimap）；
  地圖 MOD 用 pzmap Studio 選該地圖 →「遊戲內小地圖」模式輸出。
- 第三方地圖 MOD 想「自帶」minimap 支援（不進本集合包）：把渲染圖命名為約定檔名
  `minidoracat_minimap.pyramid.zip` 放進**該 MOD 自己的** `media/minimap/`，
  零 Lua，本 MOD 會自動掃描掛載（相容路徑，檔名尾綴匹配、bounds 自動對位）。
- **收錄準則**：小型／核心地圖走本集合包；大型地圖（pyramid zip 動輒數百 MB）
  建議走第三方 addon 相容路徑分開發佈，避免只玩部分地圖的玩家被迫下載全部。
- `*.pyramid.zip` 為渲染產物，**不進版控**（見專案 .gitignore）。
