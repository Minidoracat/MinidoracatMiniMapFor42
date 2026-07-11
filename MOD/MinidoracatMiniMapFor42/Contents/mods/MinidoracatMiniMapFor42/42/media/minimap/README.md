# media/minimap/ — pyramid zip 約定目錄

此目錄放置本 MOD 的基底地圖圖檔：

```
minidoracat_minimap.pyramid.zip
```

- **檔名是匹配鍵，不可改名**：遊戲內樣式層以檔名尾綴匹配所有已掛載的 zip，
  基底 MOD 與所有地圖 addon MOD 都必須使用這個相同檔名。
- 產生方式：專案根目錄執行 `scripts/build_pyramids.ps1`（呼叫 pzmap render-minimap），
  或用 pzmap Studio「遊戲內小地圖」模式輸出。
- 地圖 addon MOD 同理：把自己地圖渲染出的同名 zip 放進該 MOD 的
  `media/minimap/` 即可，零 Lua，本 MOD 會自動掃描掛載。
- `*.pyramid.zip` 為渲染產物，**不進版控**（見專案 .gitignore）。
