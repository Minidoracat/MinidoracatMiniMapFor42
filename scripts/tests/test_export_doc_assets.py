"""匯出目錄說明檔（42/media/exportdoc/_README_*.txt）的資產守衛。

這些說明檔是靜態 UTF-8 檔案，啟動時由 MinidoracatMiniMapExportReadme.lua 原封不動
複製到 Zomboid/Lua/MinidoracatMiniMap/。之所以不寫在 Lua 字面量裡：

  Lua 原始檔由 IndieFileLoader.getStreamReader 載入，主路徑是 UTF-8
  （IndieFileLoader.java:22-24），但 fallback 到 Core.getMyDocumentFolder()/mods
  時用的是 new InputStreamReader(fisx)＝平台預設編碼（:25-27）。本機 linked-mod
  走的就是 fallback——實測整段中文被讀成 U+FFFD，寫出來全是亂碼。
  改走靜態檔就全程 UTF-8：getModFileReader 明確 StandardCharsets.UTF_8
  （LuaManager.java:6005）、getFileWriter 也是（:6753-6754）。

而且說明檔是 exists-only（只在不存在時產生、之後永不覆寫），一旦寫出亂碼就會永久
留在管理員的機器上。所以這裡守三件事：

  1. Lua 檔宣告的每個來源檔都真的存在（漏檔會讓啟動時 failed 計數 +1、沒有說明檔）。
  2. 說明檔是合法 UTF-8、無 BOM、無 CRLF。
  3. ExportReadme.lua 的**非註解**行不含非 ASCII——防止有人又把中文塞回 Lua 字面量。

用法：python scripts/tests/test_export_doc_assets.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
MODV = REPO / "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42"
LUA = MODV / "media/lua/server/MinidoracatMiniMapExportReadme.lua"


def main() -> int:
    failures: list[str] = []

    lua_src = LUA.read_text(encoding="utf-8")

    # ---- 1. Lua 宣告的來源檔都要存在，且 dest 都落在 MinidoracatMiniMap/ ----
    entries = re.findall(r'\{\s*src\s*=\s*"([^"]+)"\s*,\s*dest\s*=\s*"([^"]+)"\s*\}',
                         lua_src)
    if not entries:
        failures.append("ExportReadme.lua 裡找不到任何 { src=..., dest=... } 條目")
    for src, dest in entries:
        if not src.startswith("media/"):
            failures.append(f"src 應相對 versionDir 且在 media/ 下：{src}")
        if not dest.startswith("MinidoracatMiniMap/"):
            failures.append(f"dest 應寫在 MinidoracatMiniMap/ 下：{dest}")
        path = MODV / src
        if not path.is_file():
            failures.append(f"來源檔不存在：{src}")
            continue

        # ---- 2. 編碼 ----
        raw = path.read_bytes()
        if raw.startswith(b"\xef\xbb\xbf"):
            failures.append(f"{src}: 有 BOM")
        if b"\r" in raw:
            failures.append(f"{src}: 含 CRLF")
        try:
            text = raw.decode("utf-8")
        except UnicodeDecodeError as exc:
            failures.append(f"{src}: 不是合法 UTF-8（{exc}）")
            continue
        if not text.endswith("\n"):
            failures.append(f"{src}: 檔尾缺換行")
        if "format v1" not in text.splitlines()[0]:
            failures.append(f"{src}: 第一行應帶格式版本字串（讓讀者辨識版本）")

    # 兩個語系至少都要在（使用者要求分語系檔案）
    dests = {d for _, d in entries}
    for expected in ("MinidoracatMiniMap/_README_CH.txt",
                     "MinidoracatMiniMap/_README_EN.txt"):
        if expected not in dests:
            failures.append(f"缺少語系說明檔：{expected}")

    # ---- 3. Lua 的非註解行不得含非 ASCII（中文只能待在註解或靜態檔）----
    for lineno, line in enumerate(lua_src.splitlines(), 1):
        code = line.split("--", 1)[0] if not line.lstrip().startswith("--") else ""
        bad = sorted({ch for ch in code if ord(ch) > 127})
        if bad:
            failures.append(
                f"ExportReadme.lua:{lineno} 非註解部分含非 ASCII {bad}"
                f"——Lua 字面量的非 ASCII 在 fallback 載入路徑下會壞掉，"
                f"請把文字放進 media/exportdoc/ 的靜態檔")

    print(f"checked {len(entries)} doc asset(s)")
    if failures:
        print(f"FAIL ({len(failures)}):")
        for f in failures:
            print("  -", f)
        return 1
    print("export doc assets: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
