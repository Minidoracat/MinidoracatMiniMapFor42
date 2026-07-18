#!/usr/bin/env python3
"""Regression tests for scripts/gen_poi_data.py.

Pure stdlib, no pytest dependency required -- but plain `assert` in
`test_*` functions is also pytest-discoverable, so both invocations work:
    python scripts/tests/test_gen_poi.py
    pytest scripts/tests/test_gen_poi.py
"""
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


def test_build_entries_dedups_exact_duplicates():
    """Identical (cat, x, y, w, h) rows must collapse to one entry."""
    categories = [("police", frozenset({"policeoffice"}))]
    raw = [
        {"rooms": ["policeoffice"], "x": 100, "y": 200, "width": 10, "height": 10},
        {"rooms": ["policeoffice"], "x": 100, "y": 200, "width": 10, "height": 10},
    ]
    entries, stats, dup_count = g.build_entries(raw, categories)
    assert dup_count == 1, f"expected 1 duplicate dropped, got {dup_count}"
    assert len(entries) == 1, f"expected 1 unique entry, got {len(entries)}"
    assert stats["police"] == 1


def test_build_entries_keeps_distinct_rows():
    """Two buildings with different coordinates are not duplicates."""
    categories = [("police", frozenset({"policeoffice"}))]
    raw = [
        {"rooms": ["policeoffice"], "x": 100, "y": 200, "width": 10, "height": 10},
        {"rooms": ["policeoffice"], "x": 999, "y": 200, "width": 10, "height": 10},
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
    raw = [{"rooms": ["armystorage", "oldmedical"], "x": 1, "y": 2, "width": 3, "height": 4}]
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
        {"rooms": ["policeoffice", "prisoncells"], "x": 1, "y": 2, "width": 3, "height": 4},
        {"rooms": ["prisoncells", "security"], "x": 9, "y": 9, "width": 5, "height": 5},
    ]
    entries, stats, dup_count = g.build_entries(raw, categories)
    assert len(entries) == 2
    cats = {(e["x"], e["cat"]) for e in entries}
    assert cats == {(1, "police"), (9, "prison")}


def test_priority_covers_all_categories():
    """Every parsed category key must appear in CATEGORY_PRIORITY."""
    categories = g.parse_categories(g.DEFAULT_CATEGORIES_LUA)
    missing = {key for key, _ in categories} - set(g.CATEGORY_PRIORITY)
    assert not missing, f"CATEGORY_PRIORITY missing: {missing}"


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
