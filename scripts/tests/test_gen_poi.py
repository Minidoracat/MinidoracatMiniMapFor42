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


def _room(name, *rects):
    """v2 room instance fixture: {name, level, rects=[[x,y,w,h],...]}."""
    return {"name": name, "level": 0, "rects": [list(r) for r in rects]}


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
    cats = {(e["x"], e["cat"]) for e in entries}
    assert cats == {(1, "police"), (9, "prison")}


def test_entry_bbox_anchors_to_trigger_rooms():
    """v2: the entry bbox is the union of the dominant category's trigger-room
    rects, NOT the whole building -- a mall pharmacy pins at the pharmacy."""
    categories = [("pharmacy", frozenset({"pharmacy"}))]
    raw = [_bld(
        _room("hall", (0, 0, 100, 100)),
        _room("pharmacy", (40, 60, 8, 6), (48, 60, 4, 6)),
    )]
    entries, _, _ = g.build_entries(raw, categories)
    assert len(entries) == 1
    e = entries[0]
    assert (e["x"], e["y"], e["w"], e["h"]) == (40, 60, 12, 6)


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
    assert len(entries) == 1 and entries[0]["x"] == 50
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
    assert (entries[0]["x"], entries[0]["y"]) == (10, 10)
    assert stats["prison"] == 0 and stats["pharmacy"] == 1


def test_same_building_bbox_records_merge_before_classify():
    """A basement and its ground floor are two lotheader building records with
    the same building bbox -- ONE physical building. Records merge BEFORE
    gate/priority/anchor (codex review: classifying separately kept an
    arbitrary first-wins anchor for same-cat pairs and emitted stacked
    two-cat icons for mixed pairs). The anchor unions both records' rects."""
    categories = [("food", frozenset({"bar"}))]
    raw = [
        {"rooms": [_room("bar", (10, 10, 5, 5))],
         "x": 10, "y": 10, "width": 20, "height": 20},
        {"rooms": [_room("bar", (12, 12, 8, 8))],
         "x": 10, "y": 10, "width": 20, "height": 20},
    ]
    entries, stats, dup_count = g.build_entries(raw, categories)
    assert dup_count == 1 and len(entries) == 1
    assert (entries[0]["x"], entries[0]["y"], entries[0]["w"], entries[0]["h"]) == (10, 10, 10, 10)


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
