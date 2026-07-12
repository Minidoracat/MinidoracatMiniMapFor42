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
    if bad:
        fail = True
        print(f"[FAIL] {path}")
        for n in bad:
            print(f"  局部名稱被當全域讀取（前向引用？）: {n}")
    else:
        print(f"[OK] {path}")
sys.exit(1 if fail else 0)
