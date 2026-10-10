#!/usr/bin/env python3
"""Regression tests for scripts/gen_parking_data.py (parking-lot rules).

Pure stdlib; plain `assert` in `test_*` functions, so pytest also works:
    python scripts/tests/test_gen_parking.py
"""
import sys
import tempfile
from pathlib import Path

SCRIPTS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(SCRIPTS_DIR))

import gen_parking_data as g  # noqa: E402


def _zone(x, y, w=3, h=5, name="", z=0, extra=""):
    return (f'  {{ name = "{name}", type = "ParkingStall", x = {x}, y = {y}, z = {z}, '
            f'width = {w}, height = {h}{extra} }},')


def _area(rects, cap):
    return {"rects": rects, "box": g._box(rects), "cap": cap}


def test_parse_stalls_drops_jams_yards_and_upper_levels():
    text = "\n".join([
        _zone(10, 10),                                        # unnamed stall: kept
        _zone(20, 10, name="medium", extra=', properties = { Direction = "E" }'),
        _zone(30, 10, name="trafficjamW"),                    # traffic jam on a road, any case
        _zone(40, 10, name="rtrafficjamn"),
        _zone(50, 10, name="junkyard"),
        _zone(60, 10, name="farm"),
        _zone(70, 10, name="burnt"),
        _zone(80, 10, name="mccoy"),
        _zone(90, 10, z=1),                                   # stall zones are read at level 0 only
        '  { name = "", type = "Vehicle", x = 1, y = 1, z = 0, width = 3, height = 5 },',
    ])
    assert g.parse_stalls(text) == [(10, 10, 3, 5), (20, 10, 3, 5)]


def test_single_spot_is_not_an_area():
    assert g.group_areas([(0, 0, 3, 5)]) == []


def test_row_joins_stalls_two_tiles_apart_and_coalesces_touching_ones():
    areas = g.group_areas([(0, 0, 3, 5), (3, 0, 3, 5), (8, 0, 3, 5)])  # 3 + 3 touch, then a 2-tile gap
    assert len(areas) == 1
    assert areas[0]["cap"] == 3                      # every zone counts on its own
    assert areas[0]["rects"] == [(0, 0, 6, 5), (8, 0, 3, 5)]
    assert areas[0]["box"] == (0, 0, 10, 4)
    # three tiles apart: two single spots, no area
    assert g.group_areas([(0, 0, 3, 5), (6, 0, 3, 5)]) == []


def test_rows_merge_into_one_area_up_to_eight_tiles_apart():
    row = [(0, 0, 3, 5), (3, 0, 3, 5)]
    near = g.group_areas(row + [(0, 13, 3, 5), (3, 13, 3, 5)])   # rows end at y=4, next starts at y=13: gap 8
    far = g.group_areas(row + [(0, 14, 3, 5), (3, 14, 3, 5)])    # gap 9
    assert [a["cap"] for a in near] == [4]
    assert sorted(a["cap"] for a in far) == [2, 2]


def test_rule_needs_stripes_or_six_cars_and_drops_grass_and_curbside():
    small = _area([(0, 0, 6, 5)], 2)
    big = _area([(0, 0, 18, 5)], 6)
    street = {"street": 30}
    assert g.is_parking(small, {"street_trafficlines_01_2": 4}, street)
    assert not g.is_parking(small, {}, street)
    assert not g.is_parking(_area([(0, 0, 15, 5)], 5), {}, street)
    assert g.is_parking(big, {}, {"street": 90})
    assert not g.is_parking(_area([(0, 0, 3, 5)], 1), {"street_trafficlines_01_2": 1}, street)
    assert not g.is_parking(big, {}, {"natural": 45, "street": 45})           # half on grass
    assert g.is_parking(big, {}, {"natural": 44, "street": 46})
    road = {(x, 4) for x in range(0, 18)}                                   # road over the row's edge: 3 of 5 lines near
    assert not g.is_parking(big, {}, {"street": 90}, road)
    assert g.is_parking(big, {}, {"street": 90}, {(x, 7) for x in range(0, 18)})   # 3 tiles away


def test_one_icon_per_lot_and_roads_split_lots():
    a = _area([(0, 0, 3, 20)], 4)
    b = _area([(23, 0, 3, 20)], 12)        # 20 tiles from a
    c = _area([(46, 0, 3, 20)], 4)         # 20 tiles from b
    areas = [dict(a), dict(b), dict(c)]
    assert g.mark_lots(areas, road=set()) == 1
    assert [x["icon"] for x in areas] == [False, True, False]   # nearest the capacity-weighted centre
    areas = [dict(a), dict(b), dict(c)]
    assert g.mark_lots(areas, road={(10, 5)}) == 2              # a road between a and b
    assert [x["icon"] for x in areas] == [True, True, False]
    far = [dict(a), _area([(24, 0, 3, 20)], 4)]                 # 21 tiles apart
    assert g.mark_lots(far, road=set()) == 2
    assert all(x["icon"] for x in far)
    areas = [dict(a), dict(b)]
    assert g.mark_lots(areas, road=None) == 2                   # map mods: every area is a lot
    assert all(x["icon"] for x in areas)


def test_bake_without_roads_uses_tiles_and_marks_every_area():
    original = g.stall_tiles
    tiles = {0: (30, {"street_trafficlines_01_2": 6}, {"street": 30}),   # striped pair: kept
             1: (90, {}, {"natural": 90}),                                # six cars on grass: dropped
             2: (60, {}, {"street": 60})}                                 # four plain cars: dropped
    g.stall_tiles = lambda pzmap, map_dir, areas: tiles
    try:
        with tempfile.TemporaryDirectory() as tmp:
            Path(tmp, "objects.lua").write_text("\n".join([
                _zone(0, 0), _zone(3, 0),
                _zone(0, 100, w=18), _zone(0, 200, w=12)]), encoding="utf-8")
            entries, stats = g.bake(tmp, pzmap=None, use_roads=False)
    finally:
        g.stall_tiles = original
    assert stats == {"stalls": 4, "areas": 3, "rule": 2, "road": 0, "grass": 1, "kept": 1, "lots": 1}
    assert [e["box"] for e in entries] == [(0, 0, 5, 4)]
    assert g.render_entry(entries[0]) == ("{ rn = 1, r = { { x = 0, y = 0, w = 6, h = 5 } }, "
                                          "b = { x = 0, y = 0, w = 6, h = 5 }, i = 1 }")
    with tempfile.TemporaryDirectory() as tmp:
        assert g.bake(tmp, pzmap=None) == ([], {"stalls": 0, "areas": 0, "rule": 0, "road": 0,
                                               "grass": 0, "kept": 0, "lots": 0})


if __name__ == "__main__":
    _names = sorted(name for name in globals()
                    if name.startswith("test_") and callable(globals()[name]))
    for _name in _names:
        globals()[_name]()
    print("test_gen_parking: OK")
