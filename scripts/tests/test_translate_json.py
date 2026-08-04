#!/usr/bin/env python3
"""Guard: MOD Translate/*/​*.json 必須合法 JSON、無重複 key、跨語言 key 集合對齊。

B42 翻譯是固定檔名 JSON（一檔壞全滅：一個 trailing comma 就讓該語言整份 UI.json
載入失敗、玩家看到全英文）；新 key 靠手貼多語，漏一語言該語系就顯示 raw key。

純 stdlib、雙模式（同 test_kahlua_globals.py）：
    python scripts/tests/test_translate_json.py
    pytest scripts/tests/test_translate_json.py
"""
import json
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
TRANSLATE_ROOT = (REPO_ROOT / "MOD/MinidoracatMiniMapFor42/Contents/mods"
                  / "MinidoracatMiniMapFor42/42/media/lua/shared/Translate")


def _no_dup_pairs(pairs):
    seen = set()
    dups = [k for k, _ in pairs if k in seen or seen.add(k)]
    if dups:
        raise ValueError(f"duplicate keys: {dups}")
    return dict(pairs)


def test_translate_json_valid_and_aligned():
    langs = sorted(p.name for p in TRANSLATE_ROOT.iterdir() if p.is_dir())
    assert langs, f"no language dirs under {TRANSLATE_ROOT}"
    names = sorted({f.name for lang in langs for f in (TRANSLATE_ROOT / lang).glob("*.json")})
    assert names, "no translate json files"
    problems = []
    keysets = {}
    for name in names:
        for lang in langs:
            p = TRANSLATE_ROOT / lang / name
            if not p.exists():
                problems.append(f"{lang}/{name}: missing (other languages have it)")
                continue
            try:
                data = json.loads(p.read_text(encoding="utf-8"),
                                  object_pairs_hook=_no_dup_pairs)
            except ValueError as e:  # 含 JSONDecodeError 與 dup-key
                problems.append(f"{lang}/{name}: {e}")
                continue
            keysets[(name, lang)] = set(data)
    # 跨語言 parity 只驗 mod 自有 key：vanilla 覆寫 key（如 IGUI_MapOption_PlaceNames）
    # 刻意只出現在 CH/CN/JP——vanilla EN 原生已有翻譯，mod EN 不放是正確的
    def own(ks):
        return {k for k in ks if "Minidoracat" in k}
    for name in names:
        base = keysets.get((name, langs[0]))
        if base is None:
            continue
        for lang in langs[1:]:
            ks = keysets.get((name, lang))
            if ks is None or own(ks) == own(base):
                continue
            missing = sorted(own(base) - own(ks))
            extra = sorted(own(ks) - own(base))
            problems.append(f"{name}: {lang} vs {langs[0]} missing={missing} extra={extra}")
    assert not problems, "翻譯 JSON 守衛失敗：\n" + "\n".join(problems)


if __name__ == "__main__":
    test_translate_json_valid_and_aligned()
    print("test_translate_json: OK")
