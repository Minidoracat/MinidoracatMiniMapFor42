#!/usr/bin/env python3
"""Regression tests for scripts/gen_poi_data.py.

Pure stdlib, no pytest dependency required -- but plain `assert` in
`test_*` functions is also pytest-discoverable, so both invocations work:
    python scripts/tests/test_gen_poi.py
    pytest scripts/tests/test_gen_poi.py
"""
import re
import sys
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))

import gen_poi_data as g  # noqa: E402


def test_category_count_matches_production_file():
    """Regression lock: real CATEGORIES table must parse to exactly
    EXPECTED_CATEGORY_COUNT entries (guards against the regex silently
    dropping a category, as happened with military/medical). The color
    field added after `rooms` must not break the regex."""
    categories = g.parse_categories(g.DEFAULT_CATEGORIES_LUA)
    assert len(categories) == g.EXPECTED_CATEGORY_COUNT, (
        f"expected {g.EXPECTED_CATEGORY_COUNT} categories, got {len(categories)}"
    )
    keys = [key for key, _ in categories]
    assert len(keys) == len(set(keys)), "duplicate category keys parsed"


def _room(name, *rects, level=0):
    """v2 room instance fixture: {name, level, rects=[[x,y,w,h],...]}."""
    return {"name": name, "level": level, "rects": [list(r) for r in rects]}


def _bld(*rooms):
    return {"rooms": list(rooms)}


def test_build_entries_dedups_exact_duplicates():
    """Identical (cat, x, y, w, h) rows must collapse to one entry."""
    categories = [("police", frozenset({"policeoffice"}))]
    raw = [
        _bld(_room("policeoffice", (100, 200, 10, 10))),
        _bld(_room("policeoffice", (100, 200, 10, 10))),
    ]
    entries, stats, dup_count = g.build_entries(raw, categories)
    assert dup_count == 1, f"expected 1 duplicate dropped, got {dup_count}"
    assert len(entries) == 1, f"expected 1 unique entry, got {len(entries)}"
    assert stats["police"] == 1


def test_build_entries_keeps_distinct_rows():
    """Two buildings with different coordinates are not duplicates."""
    categories = [("police", frozenset({"policeoffice"}))]
    raw = [
        _bld(_room("policeoffice", (100, 200, 10, 10))),
        _bld(_room("policeoffice", (999, 200, 10, 10))),
    ]
    entries, stats, dup_count = g.build_entries(raw, categories)
    assert dup_count == 0
    assert len(entries) == 2
    assert stats["police"] == 2


def test_build_entries_multi_category_picks_dominant():
    """A building whose rooms hit two categories produces ONE entry with the
    dominant category per CATEGORY_PRIORITY (military beats medical) -- no
    stacked icons at the same bbox."""
    categories = [
        ("medical", frozenset({"oldmedical"})),
        ("military", frozenset({"armystorage"})),
    ]
    raw = [_bld(_room("armystorage", (1, 2, 3, 4)), _room("oldmedical", (10, 2, 3, 4)))]
    entries, stats, dup_count = g.build_entries(raw, categories)
    assert dup_count == 0
    assert len(entries) == 1
    assert entries[0]["cat"] == "military"
    assert stats["military"] == 1 and stats["medical"] == 0


def test_build_entries_police_beats_prison():
    """Holding cells inside a police station stay police; a real prison
    (no police rooms) stays prison."""
    categories = [
        ("police", frozenset({"policeoffice"})),
        ("prison", frozenset({"prisoncells"})),
    ]
    raw = [
        _bld(_room("policeoffice", (1, 2, 3, 4)), _room("prisoncells", (5, 2, 3, 4))),
        _bld(_room("prisoncells", (9, 9, 5, 5)), _room("security", (14, 9, 2, 2))),
    ]
    entries, stats, dup_count = g.build_entries(raw, categories)
    assert len(entries) == 2
    cats = {(e["rects"][0][0], e["cat"]) for e in entries}
    assert cats == {(1, "police"), (9, "prison")}


def test_entry_carries_trigger_room_rects_largest_first():
    """v3: the entry carries the dominant category's trigger-room rects
    individually (NOT the building bbox, NOT a union), sorted largest first
    so rects[0] anchors the icon inside a real room."""
    categories = [("pharmacy", frozenset({"pharmacy"}))]
    raw = [_bld(
        _room("hall", (0, 0, 100, 100)),
        _room("pharmacy", (60, 60, 4, 6), (40, 60, 8, 6)),
    )]
    entries, _, _ = g.build_entries(raw, categories)
    assert len(entries) == 1
    assert entries[0]["rects"] == [(40, 60, 8, 6), (60, 60, 4, 6)]


def test_same_level_adjacent_rooms_coalesce():
    """A row of exactly-adjacent same-level rooms merges into one rect --
    fewer draw calls and no internal gridlines in block mode."""
    categories = [("school", frozenset({"classroom"}))]
    raw = [_bld(_room("classroom", (0, 0, 5, 8), (5, 0, 5, 8), (10, 0, 5, 8)))]
    entries, _, _ = g.build_entries(raw, categories)
    assert entries[0]["rects"] == [(0, 0, 15, 8)]


def test_cross_level_rooms_keep_dominant_level_only():
    """Rooms of the winning category on other floors are dropped from the
    drawn rects (2D stacking double-tints block mode); the level with the
    most category area wins, tie goes to the lowest level."""
    categories = [("food", frozenset({"restaurantdining"}))]
    raw = [_bld(
        _room("restaurantdining", (10, 10, 8, 8), level=0),
        _room("restaurantdining", (11, 11, 5, 5), level=1),
    )]
    entries, _, _ = g.build_entries(raw, categories)
    assert entries[0]["rects"] == [(10, 10, 8, 8)]


def test_entry_rects_dedup_identical_footprints():
    """Stacked floors with identical 2D footprints must not repeat a rect --
    block mode would double-tint it."""
    categories = [("medical", frozenset({"medical"}))]
    raw = [_bld(
        _room("medical", (5, 5, 4, 4)),
        _room("medical", (5, 5, 4, 4), (0, 0, 2, 2)),
    )]
    entries, _, _ = g.build_entries(raw, categories)
    assert len(entries) == 1
    assert entries[0]["rects"] == [(5, 5, 4, 4), (0, 0, 2, 2)]


def test_accessory_gate_drops_parasitic_claim():
    """A tenant storageunit inside an apartment (share < 10%) must not brand
    the building storage (player report (10051,12613)); a real self-storage
    facility (storageunit dominant) still does."""
    categories = [("storage", frozenset({"storageunit", "warehouse"}))]
    raw = [
        _bld(_room("livingroom", (0, 0, 30, 30)), _room("storageunit", (30, 0, 4, 4))),
        _bld(_room("storageunit", (50, 0, 20, 20)), _room("hall", (70, 0, 4, 4))),
    ]
    entries, stats, _ = g.build_entries(raw, categories)
    assert len(entries) == 1 and entries[0]["rects"][0][0] == 50
    assert stats["storage"] == 1


def test_accessory_gate_falls_through_to_next_category():
    """A mall whose prisoncells are parasitic (share < 10%) falls through to
    its next matched category (the real pharmacy inside), not to nothing."""
    categories = [
        ("prison", frozenset({"prisoncells"})),
        ("pharmacy", frozenset({"pharmacy"})),
    ]
    raw = [_bld(
        _room("hall", (0, 0, 60, 60)),
        _room("prisoncells", (0, 0, 5, 5)),
        _room("pharmacy", (10, 10, 8, 8)),
    )]
    entries, stats, _ = g.build_entries(raw, categories)
    assert len(entries) == 1
    assert entries[0]["cat"] == "pharmacy"
    assert entries[0]["rects"][0][:2] == (10, 10)
    assert stats["prison"] == 0 and stats["pharmacy"] == 1


def test_same_building_bbox_records_merge_before_classify():
    """A basement and its ground floor are two lotheader building records with
    the same building bbox -- ONE physical building. Records merge BEFORE
    gate/priority/anchor (codex review: classifying separately kept an
    arbitrary first-wins anchor for same-cat pairs and emitted stacked
    two-cat icons for mixed pairs); the dominant level then picks the drawn
    rects (ground bar 8x8 beats basement bar 5x5)."""
    categories = [("food", frozenset({"bar"}))]
    raw = [
        {"rooms": [_room("bar", (10, 10, 5, 5), level=-1)],
         "x": 10, "y": 10, "width": 20, "height": 20},
        {"rooms": [_room("bar", (12, 12, 8, 8), level=0)],
         "x": 10, "y": 10, "width": 20, "height": 20},
    ]
    entries, stats, dup_count = g.build_entries(raw, categories)
    assert dup_count == 1 and len(entries) == 1
    assert entries[0]["rects"] == [(12, 12, 8, 8)]


def test_mixed_cat_same_bbox_records_yield_one_entry():
    """A basement storage record + ground-floor food record of the SAME
    building must produce one dominant-category entry, not two stacked
    icons (codex review caught a 12x27 building emitting storage+food)."""
    categories = [
        ("food", frozenset({"bar"})),
        ("storage", frozenset({"storageunit"})),
    ]
    raw = [
        {"rooms": [_room("storageunit", (10, 10, 8, 8))],
         "x": 10, "y": 10, "width": 20, "height": 20},
        {"rooms": [_room("bar", (12, 12, 8, 8))],
         "x": 10, "y": 10, "width": 20, "height": 20},
    ]
    entries, stats, dup_count = g.build_entries(raw, categories)
    assert len(entries) == 1 and dup_count == 1
    assert entries[0]["cat"] == "food"
    assert stats["storage"] == 0


def test_mixed_accessory_and_shop_trigger_skips_gate():
    """A category whose trigger set contains ANY non-accessory room is exempt
    from the share gate, even at a tiny share."""
    categories = [("outdoor", frozenset({"gymstorage", "sportstore"}))]
    raw = [_bld(
        _room("hall", (0, 0, 100, 100)),
        _room("gymstorage", (100, 0, 2, 2)),
        _room("sportstore", (102, 0, 2, 2)),
    )]
    entries, _, _ = g.build_entries(raw, categories)
    assert len(entries) == 1 and entries[0]["cat"] == "outdoor"


def test_accessory_gate_accepts_exactly_at_threshold():
    """share == ACCESSORY_MIN_SHARE (exactly 10%) must be accepted -- the
    reject condition is strict less-than."""
    categories = [("storage", frozenset({"storageunit"}))]
    raw = [_bld(
        _room("livingroom", (0, 0, 90, 1)),
        _room("storageunit", (90, 0, 10, 1)),
    )]
    entries, _, _ = g.build_entries(raw, categories)
    assert len(entries) == 1 and entries[0]["cat"] == "storage"


def test_accessory_gate_fails_closed_without_area():
    """total_area == 0 (no room geometry at all) must NOT let an accessory
    claim through."""
    categories = [("storage", frozenset({"storageunit"}))]
    raw = [_bld(_room("storageunit"), _room("hall"))]
    entries, stats, _ = g.build_entries(raw, categories)
    assert entries == [] and stats["storage"] == 0


def _house(*extra_rooms):
    """獨棟民宅 fixture：總 350sq、臥室 100sq（28.6%），在住宅門檻的 reject 側。"""
    return _bld(
        _room("livingroom", (0, 0, 20, 10)),
        _room("bedroom", (0, 10, 10, 10)),
        _room("kitchen", (10, 10, 10, 5)),
        *extra_rooms,
    )


def test_house_gate_blocks_tiny_shop_room_in_a_home():
    """民宅角落的小型設施房不定義整棟身分——玩家回報 (6714,5446) 民宅裡
    2sq grocerystorage 標超市。落給下一候選（此處無 → 整棟不標）。"""
    categories = [("grocery", frozenset({"grocerystorage"}))]
    entries, stats, _ = g.build_entries(
        [_house(_room("grocerystorage", (10, 15, 2, 1)))], categories)
    assert entries == [] and stats["grocery"] == 0


def test_house_gate_falls_through_to_the_real_identity():
    """擋掉小房間後落給下一命中類別，而非整棟消失——實錘 (426,9816)：
    181sq 服飾店原被 14sq toolstore 搶標 tools，門檻擋掉後翻回 retail。"""
    categories = [
        ("tools", frozenset({"toolstore"})),
        ("retail", frozenset({"clothesstore"})),
    ]
    entries, _, _ = g.build_entries([_bld(
        _room("clothesstore", (0, 0, 20, 10)),
        _room("bedroom", (0, 10, 10, 5)),
        _room("toolstore", (10, 10, 3, 2)),
    )], categories)
    assert len(entries) == 1 and entries[0]["cat"] == "retail"


def test_house_gate_exempts_large_institutions():
    """總面積 > HOUSE_MAX_ROOM_AREA 時不套用——機構型建物的臥室是宿舍不是
    民宅。實錘 (5522,12407) March Ridge 地下地堡：bedroom 750sq 是軍營寢室，
    armystorage 91sq（0.8%）仍須標軍事。"""
    categories = [("military", frozenset({"armystorage"}))]
    entries, _, _ = g.build_entries([_bld(
        _room("hall", (0, 0, 100, 8)),
        _room("bedroom", (0, 8, 100, 2)),
        _room("armystorage", (0, 10, 5, 1)),
    )], categories)
    assert len(entries) == 1 and entries[0]["cat"] == "military"


def test_house_gate_exempts_buildings_without_bedrooms():
    """無臥室＝不是住家，小佔比店面房仍成立（原商店型豁免的核心情境：
    商場一角的藥局）。實錘：拿掉臥室條件會誤殺 7 棟店住混合的真槍店/藥局。"""
    categories = [("pharmacy", frozenset({"pharmacy"}))]
    entries, _, _ = g.build_entries([_bld(
        _room("lobby", (0, 0, 20, 10)),
        _room("pharmacy", (0, 10, 3, 2)),
    )], categories)
    assert len(entries) == 1 and entries[0]["cat"] == "pharmacy"


def test_house_gate_boundaries_are_inclusive_on_the_house_side():
    """總面積 == HOUSE_MAX_ROOM_AREA 且臥室佔比 == HOUSE_MIN_BEDROOM_SHARE 時
    仍算住家（兩者皆為 <= / >=）。800 是 761sq 民宅與 815sq 真書店之間的實測
    斷點，方向弄反會讓貼線的民宅漏網。"""
    # 700 + 80 + 20 = 800sq 恰好貼線，臥室 80/800 = 10% 恰好貼線
    entries, _, _ = g.build_entries([_bld(
        _room("livingroom", (0, 0, 100, 7)),
        _room("bedroom", (0, 7, 80, 1)),
        _room("grocerystorage", (80, 7, 20, 1)),
    )], [("grocery", frozenset({"grocerystorage"}))])
    assert entries == []


def test_house_gate_exempts_share_at_or_above_threshold():
    """佔比 >= ACCESSORY_MIN_SHARE 的店面房不受住宅門檻影響——小坪數店住
    混合（實錘 (1978,8581)：53sq 建物裡 24sq 餐飲＝45%，是路邊小吃不是民宅
    廚房）。reject 條件為嚴格小於，與 accessory gate 同水位。"""
    categories = [("food", frozenset({"diner"}))]
    entries, _, _ = g.build_entries([_bld(
        _room("livingroom", (0, 0, 10, 6)),
        _room("bedroom", (0, 6, 10, 3)),
        _room("diner", (0, 9, 10, 1)),
    )], categories)
    assert len(entries) == 1 and entries[0]["cat"] == "food"


def test_rectless_trigger_falls_through_to_next_category():
    """A higher-priority category whose trigger rooms carry no rects cannot
    anchor an entry; the building falls through to the next matched category
    instead of vanishing."""
    categories = [
        ("military", frozenset({"armystorage"})),
        ("medical", frozenset({"medical"})),
    ]
    raw = [_bld(_room("armystorage"), _room("medical", (5, 5, 4, 4)))]
    entries, stats, _ = g.build_entries(raw, categories)
    assert len(entries) == 1 and entries[0]["cat"] == "medical"
    assert stats["military"] == 0


def test_shop_trigger_has_no_share_gate():
    """Shop-type trigger rooms (not in ACCESSORY_ROOMS) claim the building at
    any share -- a tiny ground-floor pharmacy in an apartment block is real."""
    categories = [("pharmacy", frozenset({"pharmacy"}))]
    raw = [_bld(_room("livingroom", (0, 0, 40, 40)), _room("pharmacy", (40, 0, 3, 4)))]
    entries, _, _ = g.build_entries(raw, categories)
    assert len(entries) == 1 and entries[0]["cat"] == "pharmacy"


def test_order_matches_categories():
    """The production generator never reads ORDER, so this test is its only
    guard: a category missing from ORDER still renders (Cat_ defaults true)
    but gets no checkbox anywhere -- players can never turn it off, zero
    errors. Lock set(ORDER) == set(CATEGORIES keys)."""
    text = g.DEFAULT_CATEGORIES_LUA.read_text(encoding="utf-8")
    m = re.search(r"\.ORDER\s*=\s*\{([^}]*)\}", text)
    assert m, "ORDER block not found in Categories lua"
    order = re.findall(r'"([^"]+)"', m.group(1))
    keys = {key for key, _ in g.parse_categories(g.DEFAULT_CATEGORIES_LUA)}
    assert len(order) == len(set(order)), "duplicate keys in ORDER"
    assert set(order) == keys, (
        f"ORDER/CATEGORIES mismatch: only-in-ORDER={sorted(set(order) - keys)}, "
        f"only-in-CATEGORIES={sorted(keys - set(order))}"
    )


def test_every_category_has_mono_icon():
    """A category without media/ui/poi_icons/poi_<key>.png is silently
    invisible under default settings (icon mode on, block mode off) -- no log,
    no test failure anywhere else. Color icons are optional (logged fallback)."""
    icons_dir = g.SHARED_LUA_DIR.parent.parent / "ui" / "poi_icons"
    missing = [key for key, _ in g.parse_categories(g.DEFAULT_CATEGORIES_LUA)
               if not (icons_dir / f"poi_{key}.png").exists()]
    assert not missing, f"missing mono icons (category invisible by default): {missing}"


def test_priority_covers_all_categories():
    """Every parsed category key must appear in CATEGORY_PRIORITY."""
    categories = g.parse_categories(g.DEFAULT_CATEGORIES_LUA)
    missing = {key for key, _ in categories} - set(g.CATEGORY_PRIORITY)
    assert not missing, f"CATEGORY_PRIORITY missing: {missing}"


def test_new_categories_priority_tail_locked():
    """The 2026-08-06 categories sit between books and storage in a measured
    order (church<food keeps 2 cafeteria churches; electronics<retail keeps 9
    department stores; retail<food because dining parasites retail buildings;
    storage last is the identity-correction design). Reordering changes
    building ownership silently -- see gen_poi_data.py priority comment."""
    assert g.CATEGORY_PRIORITY[-7:] == [
        "electronics", "church", "farm", "industry", "retail", "food", "storage"
    ]


def test_house_gate_real_corpus_decisions_if_raw_present():
    """住宅門檻在真實 corpus 上的決策錨點。

    合成 fixture 鎖不住 corpus-derived 參數——codex review 的 mutation 實測：
    HOUSE_MAX_ROOM_AREA 800→900 或臥室條件放寬成「有臥室即可」時，其餘住宅
    門檻測試全數仍綠，但真實 corpus 分別改判 815sq 真書店與 7 棟店住混合真
    店面。上方 staleness 測試也擋不住（generator 與烘焙產物會一起漂移）。
    故逐案鎖住三個門檻條件各自的兩側，每組都是實測選出的貼線案例。
    """
    if not g.DEFAULT_RAW.exists():
        print(f"SKIP: {g.DEFAULT_RAW} not present in this checkout")
        return
    import json

    raw = json.loads(g.DEFAULT_RAW.read_text(encoding="utf-8"))
    entries, _, _ = g.build_entries(raw, g.parse_categories(g.DEFAULT_CATEGORIES_LUA))
    by_bbox = {(e["bbox"][0], e["bbox"][1]): e["cat"] for e in entries if e.get("bbox")}

    # 退場：民宅角落的小型設施房不定義整棟身分（前三筆為玩家實地回報）
    for xy, was in [((6714, 5446), "grocery"), ((6665, 5416), "medical"),
                    ((10078, 8252), "food"), ((13610, 2833), "retail")]:
        assert xy not in by_bbox, f"{xy} 應被住宅門檻擋下（先前誤標 {was}）"

    # 保留：三個條件各自的另一側，任一條件放寬/收緊都會在此炸開
    for xy, cat, why in [
            ((11891, 6872), "books", "815sq 真書店——總面積斷點上側，800→900 會誤殺"),
            ((5522, 12407), "military", "地下軍事地堡——臥室是軍營寢室不是民宅"),
            ((2168, 5737), "pharmacy", "療養院——機構型，臥室佔比高但非住家"),
            ((13054, 1993), "medical", "醫療大樓——同上"),
            ((7235, 8162), "gunstore", "店住混合真槍店——臥室 <10%，放寬臥室條件會誤殺"),
            ((12301, 1325), "gunstore", "同上"),
    ]:
        assert by_bbox.get(xy) == cat, f"{xy} 應維持 {cat}：{why}"

    # 主身分修正：門檻擋掉搶標的小房間後翻回真身分
    for xy, cat, why in [
            ((5894, 5374), "food", "182sq generalstore 原被 30sq clothesstore 搶標 retail"),
            ((426, 9816), "retail", "181sq 服飾店原被 14sq toolstore 搶標 tools"),
    ]:
        assert by_bbox.get(xy) == cat, f"{xy} 應翻回 {cat}：{why}"


def test_baked_output_matches_fresh_bake_if_raw_present():
    """Committed MinidoracatMiniMapPOIData.lua must be byte-identical to a
    fresh bake -- catches 'edited Categories.lua but forgot to re-run
    gen_poi_data.py' and hand-edited output. Skipped when poi_raw.json is
    absent (optional file, see test_default_raw_schema_if_present)."""
    if not g.DEFAULT_RAW.exists():
        print(f"SKIP: {g.DEFAULT_RAW} not present in this checkout")
        return
    import json

    raw = json.loads(g.DEFAULT_RAW.read_text(encoding="utf-8"))
    categories = g.parse_categories(g.DEFAULT_CATEGORIES_LUA)
    entries, _, _ = g.build_entries(raw, categories)
    expected = g.render_lua(entries, len(raw), "python scripts/gen_poi_data.py")
    actual = g.DEFAULT_OUT.read_text(encoding="utf-8")
    assert actual == expected, (
        "MinidoracatMiniMapPOIData.lua is stale -- re-run scripts/gen_poi_data.py"
    )


def test_room_sets_pairwise_disjoint():
    """A room name listed in two categories is a semantic conflict: priority
    silently picks one and the other category's claim becomes dead data."""
    categories = g.parse_categories(g.DEFAULT_CATEGORIES_LUA)
    seen = {}
    dupes = []
    for key, rooms in categories:
        for room in rooms:
            if room in seen:
                dupes.append((room, seen[room], key))
            seen[room] = key
    assert not dupes, f"rooms listed in multiple categories: {dupes}"


def test_room_count_snapshot():
    """Pin per-category room-key counts. Multi-line rooms arrays make silent
    edit slips (a key dropped on rewrap, a key pasted into the wrong category)
    invisible to every other test -- a count change must be deliberate and
    updated here alongside the Categories lua header."""
    expected = {
        "military": 6, "police": 17, "gunstore": 3, "medical": 16,
        "pharmacy": 2, "fire": 2, "books": 3, "school": 7,
        "grocery": 4, "gas": 4, "tools": 5, "outdoor": 8,
        "prison": 9, "storage": 2, "electronics": 3, "church": 3,
        "farm": 15, "industry": 52, "retail": 67, "food": 103,
    }
    expected["school"] = 10
    actual = {key: len(rooms) for key, rooms in g.parse_categories(g.DEFAULT_CATEGORIES_LUA)}
    assert actual == expected, (
        f"room-key counts drifted: "
        f"{ {k: (expected.get(k), actual.get(k)) for k in expected.keys() | actual.keys() if expected.get(k) != actual.get(k)} }"
    )


def test_overlapping_records_sharing_a_room_merge_as_one_building():
    """A basement and ground-floor record of the SAME building often differ by
    a few squares in bbox, so the exact-bbox key misses them -- they then draw
    two nested outlines and two icons (player screenshot: Louisville police
    (6078,5233,12,32) vs (6077,5236,14,29)). Sharing a room at identical
    coordinates is proof of one building; the merged bbox is their union."""
    categories = [("police", frozenset({"policeoffice"}))]
    shared = _room("hall", (10, 20, 2, 5))
    raw = [
        {"rooms": [shared, _room("policeoffice", (10, 25, 4, 4))],
         "x": 9, "y": 20, "width": 14, "height": 29, "level": -1},
        {"rooms": [shared, _room("policeoffice", (14, 25, 6, 4))],
         "x": 10, "y": 18, "width": 12, "height": 32, "level": 0},
    ]
    entries, stats, dup_count = g.build_entries(raw, categories)
    assert len(entries) == 1, f"same building must yield one entry, got {len(entries)}"
    assert stats["police"] == 1 and dup_count == 1
    assert entries[0]["bbox"] == (9, 18, 14, 32), "bbox must be the union of both records"


def test_shared_room_merge_survives_partial_room_overlap():
    """The merge key is a same-named room sharing ANY identical rect, not the
    whole room shape: one room's footprint legitimately differs between floors
    (real police hall is [[6080,5249,8,3],[6080,5252,3,8]] in the basement vs
    [[6078,5249,6,3],[6080,5252,3,8]] above), and a single shared rect is the
    stairwell square. Requiring identical whole-room geometry would miss these."""
    categories = [("police", frozenset({"policeoffice"}))]
    raw = [
        {"rooms": [_room("hall", (10, 20, 8, 3), (12, 23, 3, 8)),
                   _room("policeoffice", (10, 30, 4, 4))],
         "x": 9, "y": 20, "width": 14, "height": 29, "level": -1},
        {"rooms": [_room("hall", (10, 20, 6, 3), (12, 23, 3, 8)),
                   _room("policeoffice", (16, 30, 6, 4))],
         "x": 10, "y": 18, "width": 12, "height": 32, "level": 0},
    ]
    entries, _, _ = g.build_entries(raw, categories)
    assert len(entries) == 1, "one shared rect (the stairwell) must merge the floors"


def test_shared_room_merge_collapses_cross_category_double_icons():
    """The split didn't just double the outline -- each record was classified
    on its own, so one building could carry two different category icons
    (real corpus had books+grocery, medical+pharmacy, grocery+gunstore,
    food+tools). After merging, priority picks a single identity."""
    categories = [
        ("gunstore", frozenset({"gunstore"})),
        ("grocery", frozenset({"grocerystorage"})),
    ]
    raw = [
        {"rooms": [_room("hall", (49, 56, 5, 1)), _room("grocerystorage", (48, 59, 4, 4))],
         "x": 42, "y": 56, "width": 16, "height": 7, "level": -1},
        {"rooms": [_room("hall", (49, 56, 5, 1)), _room("gunstore", (47, 68, 4, 2))],
         "x": 43, "y": 56, "width": 18, "height": 44, "level": 0},
    ]
    entries, stats, _ = g.build_entries(raw, categories)
    assert len(entries) == 1, "one building must not carry two category icons"
    assert entries[0]["cat"] == "gunstore" and stats["grocery"] == 0


# 分組合併的完整快照（27 組＝第一道 bbox 全等 10 組＋第二道共享 rect 17 組）。
# 只鎖組數不夠：組數相同但成員被等量替換（拿掉一組真 pair、換進一組假 pair）仍會
# 全綠（codex review 以記憶體反例證明）。鎖 building_id 才是 pair identity。
EXPECTED_MERGE_GROUPS = [
    ('10_56_0', '10_56_16'), ('14_24_0', '14_24_1'), ('14_48_0', '14_48_2'),
    ('1_38_1', '1_38_16'), ('23_20_0', '23_20_50'), ('24_20_0', '24_20_11'),
    ('24_20_4', '24_20_40'), ('25_20_1', '25_20_11'), ('25_20_3', '25_20_47'),
    ('26_21_18', '26_21_2'), ('28_32_2', '28_32_35'), ('29_46_1', '29_46_7'),
    ('2_38_0', '2_38_30'), ('31_44_0', '31_44_24'), ('31_45_24', '31_45_4'),
    ('32_46_0', '32_46_5'), ('32_46_16', '33_46_2'), ('33_46_0', '33_46_7'),
    ('33_46_10', '33_46_5'), ('42_39_0', '42_39_38'), ('46_26_0', '46_26_21'),
    ('46_26_1', '46_26_4'), ('46_26_3', '46_26_58'), ('7_38_0', '7_38_3'),
    ('8_22_0', '8_22_33'), ('8_25_0', '8_25_14'), ('9_54_1', '9_54_24'),
]


def test_shared_fragment_rooms_are_on_distinct_levels():
    """The merge key's physical argument, tested directly: a square of ground
    can hold only ONE room per floor, so two records sharing a same-named rect
    must have that room on DIFFERENT levels (a vertical stack = one building).
    Two records sharing a fragment at the SAME room level would be a
    contradiction -- the key merged genuinely different buildings.

    Checking building["level"] instead is NOT equivalent: that field is the
    lowest floor across all of a record's rooms, so a same-level fragment pair
    can still show -1/0 at the building level (codex review's counterexample)."""
    if not g.DEFAULT_RAW.exists():
        print(f"SKIP: {g.DEFAULT_RAW} not present in this checkout")
        return
    import json

    raw = json.loads(g.DEFAULT_RAW.read_text(encoding="utf-8"))
    groups, _ = g.group_records(raw)
    merged = [recs for recs in groups.values() if len(recs) > 1]
    assert merged, "expected the corpus to exercise the merge"

    def fragment_levels(rec):
        """(room name, rect) -> set of levels that room occupies in this record."""
        out = {}
        for room in rec.get("rooms") or ():
            name = room.get("name")
            if not name:
                continue
            for rect in room.get("rects") or ():
                out.setdefault((name, tuple(rect)), set()).add(room.get("level"))
        return out

    bad = []
    for recs in merged:
        maps = [fragment_levels(r) for r in recs]
        for i in range(len(maps)):
            for j in range(i + 1, len(maps)):
                for key in maps[i].keys() & maps[j].keys():
                    clash = maps[i][key] & maps[j][key]
                    if clash:
                        bad.append((recs[i]["building_id"], recs[j]["building_id"],
                                    key, sorted(clash)))
    assert not bad, (
        f"records merged on a fragment shared at the SAME room level "
        f"(two rooms on one square = different buildings): {bad[:3]}"
    )


def test_merge_groups_exact_snapshot():
    """Pin WHICH records merge, not just how many. Every deviation -- a wider
    key, a narrower key, or an equal-count swap of one pair for another -- has
    to be reviewed by hand. Mutation-verified: dropping the room name from the
    key yields 43 groups, dropping the rect yields groups that violate the
    level invariant, disabling stage two yields 10."""
    if not g.DEFAULT_RAW.exists():
        print(f"SKIP: {g.DEFAULT_RAW} not present in this checkout")
        return
    import json

    raw = json.loads(g.DEFAULT_RAW.read_text(encoding="utf-8"))
    groups, _ = g.group_records(raw)
    merged = [recs for recs in groups.values() if len(recs) > 1]
    oversized = [[r["building_id"] for r in recs] for recs in merged if len(recs) > 2]
    assert not oversized, (
        f"a merge component grew past a basement/ground pair: {oversized}. "
        f"Transitive merges need manual review -- they can chain unrelated "
        f"buildings through a common fragment."
    )
    actual = sorted(tuple(sorted(r["building_id"] for r in recs)) for recs in merged)
    assert actual == sorted(EXPECTED_MERGE_GROUPS), (
        f"merge groups drifted: "
        f"only-now={sorted(set(actual) - set(EXPECTED_MERGE_GROUPS))[:5]}, "
        f"only-before={sorted(set(EXPECTED_MERGE_GROUPS) - set(actual))[:5]}"
    )


def test_merged_records_overlap_and_span_levels():
    """Shape check on every merged group: members must overlap in 2D and their
    buildings must sit on different lowest floors -- the basement/ground
    signature. Weaker than the two tests above; kept as a cheap tripwire."""
    if not g.DEFAULT_RAW.exists():
        print(f"SKIP: {g.DEFAULT_RAW} not present in this checkout")
        return
    import json

    raw = json.loads(g.DEFAULT_RAW.read_text(encoding="utf-8"))
    groups, _ = g.group_records(raw)

    def overlaps(a, b):
        return (max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
                * max(0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))) > 0

    bad = []
    for recs in groups.values():
        if len(recs) < 2:
            continue
        boxes = [(r["x"], r["y"], r["width"], r["height"]) for r in recs]
        levels = [r.get("level") for r in recs]
        pairwise = all(overlaps(boxes[i], boxes[j])
                       for i in range(len(boxes))
                       for j in range(i + 1, len(boxes)))
        if not pairwise or len(set(levels)) != len(levels):
            bad.append((boxes, levels))
    assert not bad, f"grouping joined non-basement/ground records: {bad[:3]}"


def test_adjacent_buildings_without_shared_rooms_stay_separate():
    """Overlapping bboxes alone must NOT merge: a mall bbox can contain a
    separately-recorded shop. Only identical-coordinate rooms merge (the real
    corpus has 60 overlapping same-level pairs, all with zero shared rooms)."""
    categories = [("police", frozenset({"policeoffice"})),
                  ("pharmacy", frozenset({"pharmacy"}))]
    raw = [
        {"rooms": [_room("policeoffice", (0, 0, 40, 40))],
         "x": 0, "y": 0, "width": 100, "height": 100},
        {"rooms": [_room("pharmacy", (50, 50, 4, 4))],
         "x": 50, "y": 50, "width": 6, "height": 6},
    ]
    entries, _, _ = g.build_entries(raw, categories)
    assert len(entries) == 2, "nested-but-unrelated buildings must stay separate"


def test_dedup_identity_includes_bbox():
    """Two buildings that land on identical (cat, room rects) but different
    bboxes must not collapse -- that would silently drop one outline. Needs
    DIFFERENT room names at the same coordinates, otherwise the shared-room
    merge (correctly) treats them as one building first."""
    categories = [("police", frozenset({"policeoffice", "policehall"}))]
    raw = [
        {"rooms": [_room("policeoffice", (5, 5, 4, 4))],
         "x": 0, "y": 0, "width": 20, "height": 20},
        {"rooms": [_room("policehall", (5, 5, 4, 4))],
         "x": 0, "y": 0, "width": 40, "height": 40},
    ]
    entries, _, _ = g.build_entries(raw, categories)
    assert len(entries) == 2, "identical rects but different bbox are two buildings"
    assert {e["bbox"] for e in entries} == {(0, 0, 20, 20), (0, 0, 40, 40)}


def test_entry_carries_whole_building_bbox():
    """The entry carries the building bbox as `bbox` (the grouping key) so the
    client can draw one outline per building. It is NOT the union of the room
    rects -- a corner pharmacy claims a mall-sized building."""
    categories = [("pharmacy", frozenset({"pharmacy"}))]
    raw = [{"rooms": [_room("hall", (0, 0, 90, 90)), _room("pharmacy", (5, 5, 4, 6))],
            "x": 0, "y": 0, "width": 100, "height": 80}]
    entries, _, _ = g.build_entries(raw, categories)
    assert entries[0]["bbox"] == (0, 0, 100, 80)
    assert entries[0]["rects"] == [(5, 5, 4, 6)], "room rects must stay per-room"


def test_entry_bbox_none_without_bbox_fields():
    """Records with no bbox fields (fixtures) group by index and carry no
    bbox -- render_lua must omit `b` so the client falls back to per-room."""
    categories = [("police", frozenset({"policeoffice"}))]
    entries, _, _ = g.build_entries([_bld(_room("policeoffice", (1, 2, 3, 4)))], categories)
    assert entries[0]["bbox"] is None
    assert " b = {" not in g.render_lua(entries, 1, "cmd")


def test_render_lua_emits_bbox_field():
    categories = [("police", frozenset({"policeoffice"}))]
    raw = [{"rooms": [_room("policeoffice", (1, 2, 3, 4))],
            "x": 0, "y": 1, "width": 20, "height": 30}]
    entries, _, _ = g.build_entries(raw, categories)
    line = [ln for ln in g.render_lua(entries, 1, "cmd").splitlines()
            if ln.startswith("    { cat =")][0]
    assert line.endswith('b = { x = 0, y = 1, w = 20, h = 30 } },'), line


def test_bbox_contains_room_rects_in_production_data():
    """Whole-building outline must be a superset of the drawn room rects --
    otherwise the 'whole building' mode would clip off rooms it claims to
    contain. Real corpus, all entries."""
    if not g.DEFAULT_RAW.exists():
        print(f"SKIP: {g.DEFAULT_RAW} not present in this checkout")
        return
    import json

    raw = json.loads(g.DEFAULT_RAW.read_text(encoding="utf-8"))
    entries, _, _ = g.build_entries(raw, g.parse_categories(g.DEFAULT_CATEGORIES_LUA))
    bad = []
    for e in entries:
        b = e["bbox"]
        if not b:
            continue
        bx, by, bw, bh = b
        for x, y, w, h in e["rects"]:
            if x < bx or y < by or x + w > bx + bw or y + h > by + bh:
                bad.append((b, (x, y, w, h)))
                break
    assert not bad, f"{len(bad)} entries have room rects outside the bbox: {bad[:3]}"


def test_build_entries_skips_buildings_without_rooms():
    categories = [("police", frozenset({"policeoffice"}))]
    raw = [{"rooms": [], "x": 1, "y": 2, "width": 3, "height": 4}]
    entries, stats, dup_count = g.build_entries(raw, categories)
    assert entries == []
    assert dup_count == 0


def test_default_raw_schema_if_present():
    """scripts/poi_raw.json is optional (clean checkout may not have it --
    see the --raw error message in main()); if present, sanity-check shape."""
    if not g.DEFAULT_RAW.exists():
        print(f"SKIP: {g.DEFAULT_RAW} not present in this checkout")
        return
    import json

    raw_buildings = json.loads(g.DEFAULT_RAW.read_text(encoding="utf-8"))
    assert isinstance(raw_buildings, list) and raw_buildings, "poi_raw.json must be a non-empty array"
    required = {"building_id", "rooms", "x", "y", "width", "height", "level"}
    sample = raw_buildings[0]
    missing = required - sample.keys()
    assert not missing, f"poi_raw.json entries missing fields: {missing}"
    # v2 (2026-08-06): rooms are per-instance objects with their own geometry.
    room = sample["rooms"][0]
    assert {"name", "level", "rects"} <= room.keys(), f"v2 room shape missing: {room.keys()}"
    assert room["rects"] and len(room["rects"][0]) == 4, "room rects must be [x,y,w,h]"


def main():
    tests = [(name, fn) for name, fn in sorted(globals().items()) if name.startswith("test_")]
    failed = []
    for name, fn in tests:
        try:
            fn()
            print(f"[PASS] {name}")
        except AssertionError as e:
            failed.append(name)
            print(f"[FAIL] {name}: {e}")
    print(f"\n{len(tests) - len(failed)}/{len(tests)} passed")
    if failed:
        sys.exit(1)


if __name__ == "__main__":
    main()
