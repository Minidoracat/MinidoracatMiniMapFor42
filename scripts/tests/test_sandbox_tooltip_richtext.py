"""沙盒選項 tooltip 的 rich text 安全性測試。

沙盒選項的說明文字最後是交給 ISToolTip 的 ISRichTextPanel 渲染，所以文案裡不能
出現角括號：

1. **`<` 是致命的**。tokenizer 以空格切（ISRichTextPanel.lua:459），中日文沒有
   空格，整句會連成同一個 token；:462-465 偵測到 `>` 就把 token 截到 `>`，
   :468-486 走 command 分支只取 `<...>` 內的字串丟給 processCommand，
   **同一 token 內 `<` 之前的文字完全不會被寫進 self.lines**——也就是說
   ``輸出 .../players_<存檔名>.json`` 會讓 ``.../players_`` 整段憑空消失。
   原版沙盒 tooltip 自己也在用 rich text 標記（``<BHC>``、``<RGB:1,1,1>``），
   這是設計行為，寫文案時就得避開。單獨的 `>`（英文 ``N > 0``）安全，因為條件
   要求 `<` 與 `>` 同時出現。

2. 換行兩種寫法都能用，但本專案統一用**實體** LF。字面 ``\n`` 也會換行——新遊戲頁
   SandboxOptions.lua:665-666 與伺服器設定頁 ServerSettingsScreen.lua:2522-2525
   都會在交給控制項前做 ``tooltip:gsub("\\n", "\n")``；實體 LF 則由
   ISRichTextPanel.lua:445 換成兩側帶空格的 ``<LINE>``。這裡擋字面 ``\n`` 純粹是
   要求同一個檔案只有一種寫法，不是因為它會壞。

本測試把 ISRichTextPanel:440-486 的字串處理逐句移植過來，對四語 Sandbox.json
的每個值跑一遍，斷言沒有任何可見文字被吞掉。

用法：python scripts/tests/test_sandbox_tooltip_richtext.py
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BASE = (REPO / "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42"
        / "42/media/lua/shared/Translate")
LANGS = ("CH", "CN", "EN", "JP")


def paginate(text: str) -> tuple[str, list[str]]:
    """移植 ISRichTextPanel:440-486 的 tokenizer。

    回傳 (會被畫出的文字, 被 command 分支吞掉的文字片段)。
    """
    left = text + " "
    left = left.replace("\n", " <LINE> ")          # :445
    drawn: list[str] = []
    dropped: list[str] = []
    cur = 0
    while True:
        idx = left.find(" ", cur)                  # :459（Lua 是 1-based find(cur+1)）
        if idx == -1:
            break
        token = left[:idx + 1]                     # :461 string.sub(leftText, 0, cur)
        if "<" in token and ">" in token:          # :462-465 補救「> 後缺空格」
            cut = token.index(">") + 1
            token = left[:cut]
            left = left[cut:]
        else:
            left = left[idx:]
        cur = 1
        if "<" in token and ">" in token:          # :468 command 分支
            pre = token[:token.index("<")]
            if pre.strip():
                dropped.append(pre)                # :475-486 完全沒寫進 self.lines
        else:
            drawn.append(token)                    # :487+ 正常文字
    return "".join(drawn), dropped


def main() -> int:
    failures: list[str] = []
    checked = 0
    for lang in LANGS:
        path = BASE / lang / "Sandbox.json"
        raw = path.read_bytes()
        if raw.startswith(b"\xef\xbb\xbf"):
            failures.append(f"{lang}: 檔案有 BOM")
            continue
        data = json.loads(raw.decode("utf-8"))
        for key, value in data.items():
            checked += 1
            if "\\n" in value:
                failures.append(
                    f"{lang}/{key}: 含字面 \\n——本專案統一用實體換行"
                    f"（兩種寫法都會換行，這裡只要求一致）")
            if "<" in value:
                failures.append(
                    f"{lang}/{key}: 含 '<'——rich text tokenizer 會把它當標記，"
                    f"並丟棄同 token 內 '<' 之前的文字")
            drawn, dropped = paginate(value)
            if dropped:
                failures.append(
                    f"{lang}/{key}: 有文字會被 rich text 吞掉：{dropped!r}")
            # 換行後每個邏輯行都必須留下可見文字（抓「\n\n」或行首標記造成的空行）
            for piece in value.split("\n"):
                if piece == "":
                    failures.append(f"{lang}/{key}: 出現空行（連續換行）")

    print(f"checked {checked} translation values across {len(LANGS)} languages")
    if failures:
        print(f"FAIL ({len(failures)}):")
        for f in failures:
            print("  -", f)
        return 1
    print("sandbox tooltip rich-text safety: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
