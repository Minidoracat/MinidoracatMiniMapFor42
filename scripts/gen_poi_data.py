#!/usr/bin/env python3
"""Bake poi_raw.json building data into MinidoracatMiniMapPOIData.lua.

Reads the flat building list in poi_raw.json ({building_id, rooms, x, y,
width, height, level}, world square coordinates) and the room->category
mapping in MinidoracatMiniMapPOICategories.lua, then emits one POI entry per
(building, matching category). A building whose rooms intersect more than one
category's room set produces one entry per matching category (same bbox,
different cat). Buildings on any level (including level > 0 upper floors)
are processed identically -- level is not a filter.

Output is deterministic: entries are sorted by (cat, x, y), so re-running
with unchanged inputs produces a byte-identical file.

Usage:
    python scripts/gen_poi_data.py [--raw PATH] [--out PATH]
"""
import argparse
import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SHARED_LUA_DIR = (
    REPO_ROOT
    / "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42"
    / "42/media/lua/shared"
)
DEFAULT_RAW = REPO_ROOT / "scripts/poi_raw.json"
DEFAULT_CATEGORIES_LUA = SHARED_LUA_DIR / "MinidoracatMiniMapPOICategories.lua"
DEFAULT_OUT = SHARED_LUA_DIR / "MinidoracatMiniMapPOIData.lua"

# 只擷取 nameKey + rooms（key、rooms 內容）。rooms 收尾的 `},` 之後允許任意欄位
# （如 color = { r, g, b }），故 regex 在 rooms 結束即停，不要求 entry 立即收合——
# 對 entry 內註解仍脆弱（見 CATEGORIES 檔頭警告），數量對不上時硬性失敗。
CATEGORY_BLOCK_RE = re.compile(
    r'(\w+)\s*=\s*\{\s*nameKey\s*=\s*"[^"]*",\s*rooms\s*=\s*\{([^}]*)\}\s*,',
)
ROOM_LITERAL_RE = re.compile(r'"([^"]+)"')

# MinidoracatMiniMapPOICategories.lua 定義 14 類（原 15，ranger 因全圖 0 筆資料於
# 0.8.0 移除）。CATEGORY_BLOCK_RE 對 entry 內註解很脆弱（曾在 military/medical 整類
# 靜默消失），數量對不上時硬性失敗好過生出漏類別的資料。未來合法新增/移除類別時，
# 改這個常數即可。
EXPECTED_CATEGORY_COUNT = 14


def parse_categories(categories_lua_path):
    """Return an ordered list of (category_key, frozenset(room_names))."""
    text = categories_lua_path.read_text(encoding="utf-8")
    categories = []
    for match in CATEGORY_BLOCK_RE.finditer(text):
        key = match.group(1)
        rooms = frozenset(ROOM_LITERAL_RE.findall(match.group(2)))
        categories.append((key, rooms))
    if len(categories) != EXPECTED_CATEGORY_COUNT:
        print(
            f"WARNING: parsed {len(categories)} categories from "
            f"{categories_lua_path.name}, expected {EXPECTED_CATEGORY_COUNT}. "
            f"CATEGORY_BLOCK_RE likely dropped an entry (e.g. an inline "
            f"comment inside the entry). If a category was legitimately "
            f"added/removed, update EXPECTED_CATEGORY_COUNT in gen_poi_data.py."
        )
    assert len(categories) == EXPECTED_CATEGORY_COUNT, (
        f"parse_categories found {len(categories)} categories, expected "
        f"{EXPECTED_CATEGORY_COUNT}"
    )
    return categories


# 主身分優先級鏈：一棟建築命中多類時只取最前面的一類（dominant category）。
# 動機：附屬房間造成語意噪音與同心疊圖標——警局的拘留室(prisoncells)不是監獄、
# 監獄的圖書室不是書店、學校的保健室(medical)不是診所。越「專屬/稀有」的身分
# 越優先；school 排在 medical 前（學校常含保健室，醫院不會含教室）、police 排在
# prison 前（拘留室在警局內；真監獄無 police 房間，仍歸 prison）。
CATEGORY_PRIORITY = [
    "military", "police", "prison", "fire", "school", "pharmacy", "medical",
    "gunstore", "grocery", "gas", "outdoor", "tools", "books", "storage",
]
_PRIORITY_INDEX = {key: i for i, key in enumerate(CATEGORY_PRIORITY)}


def build_entries(raw_buildings, categories):
    """Return (entries, stats, dup_count).

    每棟建築依 CATEGORY_PRIORITY 只產出一個主身分條目（見上方註解）。
    stats maps category_key -> unique hit count (post-dedup).
    dup_count is how many (cat, x, y, w, h) duplicates were dropped.
    """
    seen = {}
    dup_count = 0
    stats = {key: 0 for key, _ in categories}
    for building in raw_buildings:
        room_set = set(building.get("rooms") or ())
        if not room_set:
            continue
        matched = [key for key, rooms in categories if room_set & rooms]
        if not matched:
            continue
        key = min(matched, key=lambda k: _PRIORITY_INDEX.get(k, len(CATEGORY_PRIORITY)))
        dedup_key = (key, building["x"], building["y"], building["width"], building["height"])
        if dedup_key in seen:
            dup_count += 1
            continue
        seen[dedup_key] = {
            "cat": key,
            "x": building["x"],
            "y": building["y"],
            "w": building["width"],
            "h": building["height"],
        }
        stats[key] += 1
    entries = list(seen.values())
    entries.sort(key=lambda e: (e["cat"], e["x"], e["y"]))
    return entries, stats, dup_count


def render_lua(entries, raw_count, gen_command):
    lines = [
        "-- MinidoracatMiniMapPOIData.lua",
        "-- 由 scripts/gen_poi_data.py 產生，請勿手動編輯。重新分類請改",
        "-- MinidoracatMiniMapPOICategories.lua 後重新執行：",
        f"--   {gen_command}",
        "--",
        f"-- 來源：poi_raw.json（{raw_count} 筆建築原始資料，世界 square 座標）。",
        "-- 消費契約見 MinidoracatMiniMapPOI.lua buildPoiConverted()：陣列，",
        "-- 每項 { cat=<CATEGORIES 類別 key>, x=, y=, w=, h= }（世界 square 座標，",
        "-- x/y 左上角、w/h 尺寸）。count 為除錯輔助欄位（Kahlua # 不可信，勿用於迭代）。",
        "",
        "MinidoracatMiniMapPOIData = {",
    ]
    for e in entries:
        lines.append(
            f'    {{ cat = "{e["cat"]}", x = {e["x"]}, y = {e["y"]}, '
            f'w = {e["w"]}, h = {e["h"]} }},'
        )
    lines.append("}")
    lines.append("")
    lines.append(f"MinidoracatMiniMapPOIData.count = {len(entries)}")
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", type=Path, default=DEFAULT_RAW, help="poi_raw.json path")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="output .lua path")
    args = parser.parse_args()

    if not args.raw.exists():
        parser.error(
            f"raw building data not found: {args.raw}\n"
            f"Pass --raw <path> pointing at the exported poi_raw.json (flat "
            f"building list; see module docstring), or place the file at "
            f"{DEFAULT_RAW}."
        )

    raw_buildings = json.loads(args.raw.read_text(encoding="utf-8"))
    categories = parse_categories(DEFAULT_CATEGORIES_LUA)
    missing = {key for key, _ in categories} - set(CATEGORY_PRIORITY)
    assert not missing, f"CATEGORY_PRIORITY missing keys: {missing}"
    entries, stats, dup_count = build_entries(raw_buildings, categories)

    gen_command = "python scripts/gen_poi_data.py"
    lua_text = render_lua(entries, len(raw_buildings), gen_command)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8", newline="\n") as f:
        f.write(lua_text)

    print(f"raw buildings: {len(raw_buildings)}")
    print(f"poi entries:   {len(entries)} ({dup_count} duplicate rows dropped)")
    print(f"output:        {args.out}")
    print("category hits:")
    zero_hit = []
    for key, _ in categories:
        count = stats[key]
        print(f"  {key:10s} {count}")
        if count == 0:
            zero_hit.append(key)
    if zero_hit:
        print(f"zero-hit categories: {', '.join(zero_hit)}")
    else:
        print("zero-hit categories: (none)")


if __name__ == "__main__":
    main()
