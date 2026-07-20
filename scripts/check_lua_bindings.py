# -*- coding: utf-8 -*-
"""檢查 mod Lua 是否把「檔案內 local 名稱」誤綁成全域讀取（前向引用陷阱）。

Lua 的 local 只有宣告後可見：先呼叫、後定義的 local function 會被編譯成
全域查找（GETTABUP _ENV），執行期拿到 nil。此檢查掃 luac 反組譯輸出，
凡是「檔內宣告過的 local 名稱」出現在全域讀取指令中即報錯。

用法：python scripts/check_lua_bindings.py <file.lua> [...]
"""
import re
import subprocess
import sys

fail = False
for path in sys.argv[1:]:
    src = open(path, encoding="utf-8").read()
    names = set()
    for m in re.finditer(r"^\s*local\s+function\s+([A-Za-z_]\w*)", src, re.M):
        names.add(m.group(1))
    for m in re.finditer(r"^\s*local\s+([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)", src, re.M):
        for n in m.group(1).split(","):
            names.add(n.strip())
    dump = subprocess.run(["luac", "-p", "-l", path], capture_output=True, text=True).stdout
    bad = sorted({m.group(1) for m in re.finditer(r'GETTABUP\b.*?_ENV\s+"([A-Za-z_]\w*)"', dump)
                  if m.group(1) in names})
    # Kahlua 編譯器每個函式原型 locvar 上限 200（LexState.new_localvar 固定陣列，
    # 超過＝整檔載入失敗；數字 for 佔 4 個 locvar）。PUC luac 只限制「同時存活」數
    # 所以攔不到——用 luac -l 的每原型 locals 總數把關，196 起即擋（留 5 餘裕）。
    # 實例：0.9.0 滑條化曾把主 chunk 撞到 203、unifiedRebuild 211 → 遊戲內整檔死亡
    over = []
    for m in re.finditer(r"^(main|function) <[^>]*:(\d+),\d+>.*?(\d+) locals", dump, re.M):
        if int(m.group(3)) > 195:
            over.append((m.group(1), m.group(2), int(m.group(3))))
    if over:
        fail = True
        print(f"[FAIL] {path}")
        for kind, line, n in over:
            print(f"  {kind}（行 {line}）locvar 共 {n} 個，貼近 Kahlua 上限 200——請合併頂層 local 或把迴圈收進子函式")
    if bad:
        fail = True
        print(f"[FAIL] {path}")
        for n in bad:
            print(f"  局部名稱被當全域讀取（前向引用？）: {n}")
    elif not over:
        print(f"[OK] {path}")
sys.exit(1 if fail else 0)
