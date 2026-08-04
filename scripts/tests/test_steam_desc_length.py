#!/usr/bin/env python3
"""Guard: Steam Workshop 描述有 8000 bytes 上限（UTF-8 bytes，非字元數）。

實例（0.11.0 發版）：加兩條功能 bullet 後 EN 8,356 bytes、JP 10,207 bytes，
網頁語言槽儲存直接失敗「儲存標題和描述時發生問題」——JP 字元數（4,661）沒超
但 bytes 超，證明 Steam 按 bytes 計。閾值取 7,900 留餘裕；超標＝發版前先瘦身
（三語同步精簡，AGENTS.md 鐵則：三語內容一致）。

純 stdlib、雙模式（同 test_kahlua_globals.py）：
    python scripts/tests/test_steam_desc_length.py
    pytest scripts/tests/test_steam_desc_length.py
"""
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
LIMIT = 7900
FILES = ["STEAM_DESCRIPTION.md", "STEAM_DESCRIPTION_EN.md", "STEAM_DESCRIPTION_JP.md"]


def test_steam_descriptions_under_byte_limit():
    over = []
    for name in FILES:
        p = REPO_ROOT / name
        assert p.exists(), f"{name} missing"
        n = len(p.read_text(encoding="utf-8").encode("utf-8"))
        if n > LIMIT:
            over.append(f"{name}: {n} bytes (limit {LIMIT}, Steam hard cap 8000)")
    assert not over, (
        "Steam 描述超過 bytes 上限（網頁語言槽會存不進去）：\n" + "\n".join(over)
    )


if __name__ == "__main__":
    test_steam_descriptions_under_byte_limit()
    print("test_steam_desc_length: OK")
