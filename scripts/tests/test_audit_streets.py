#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""audit_streets.py 守衛：strict provenance／XML、partial coverage、安全輸出與 candidate gates。

純 stdlib、雙模式：
    python scripts/tests/test_audit_streets.py
    pytest scripts/tests/test_audit_streets.py

fixtures 在測試內生成，不解析地圖 binary。
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import itertools
import random
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "audit_streets.py"
SPEC = importlib.util.spec_from_file_location("audit_streets", SCRIPT)
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)

CLASSES = list(M.CLASSES)
CID = M.CLASS_ID
CELL = 256
SQUARES = CELL * CELL


def _root(tmp_path):
    # 雙模式：pytest 給 tmp_path，直跑時自建暫存目錄
    return Path(tmp_path) if tmp_path else Path(tempfile.mkdtemp())


def _write_json(path, obj):
    path.write_bytes(M.dumps_canonical(obj).encode("utf-8"))


def _write_streets(path, streets):
    lines = ['<streets version="1">']
    for name, width, pts in streets:
        lines.append('    <street name="%s" width="%s">' % (name, width))
        lines.append("        <points>")
        for x, y in pts:
            lines.append('            <point x="%.1f" y="%.1f"/>' % (x, y))
        lines.append("        </points>")
        lines.append("    </street>")
    lines.append("</streets>")
    lines.append("")
    path.write_bytes("\n".join(lines).encode("utf-8"))


def _runs_from_grid(grid):
    flat = [v for row in grid for v in row]
    runs = []
    i = 0
    for v, group in itertools.groupby(flat):
        n = len(list(group))
        runs.append([i, n, v])
        i += n
    return runs


def _paint(grid, x0, y0, x1, y1, cid):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            grid[y][x] = cid


def _surface_source(cells, mode="full", requested_region=None):
    coords = [(cell["x"], cell["y"]) for cell in cells]
    bounds = [
        min(cx for cx, _ in coords),
        min(cy for _, cy in coords),
        max(cx for cx, _ in coords),
        max(cy for _, cy in coords),
    ]
    if mode == "region" and requested_region is None:
        requested_region = list(bounds)
    return {
        "pzBuild": "42.test",
        "scope": {
            "mode": mode,
            "requestedRegion": requested_region,
            "selectedCellCount": len(coords),
            "bounds": bounds,
        },
        "inputs": [{
            "priority": 0,
            "layer": "fixture",
            "cells": [
                [cx, cy, "%d_%d.lotheader" % (cx, cy),
                 "world_%d_%d.lotpack" % (cx, cy)]
                for cx, cy in sorted(coords, key=lambda item: (item[1], item[0]))
            ],
        }],
    }


def _surface_doc(cells, map_id="fixture", mode="full", requested_region=None):
    cells = sorted(cells, key=lambda cell: (cell["y"], cell["x"]))
    return {
        "schemaVersion": 1,
        "mapId": map_id,
        "cellSize": 256,
        "source": _surface_source(cells, mode, requested_region),
        "classes": CLASSES,
        "cells": cells,
    }


def _surface_cell(cx, cy, paints):
    grid = [[0] * CELL for _ in range(CELL)]
    for x0, y0, x1, y1, name in paints:
        _paint(grid, x0, y0, x1, y1, CID[name])
    return {"x": cx, "y": cy, "runs": _runs_from_grid(grid)}


def _write_surfaces(path, paints, map_id="fixture", mode="full"):
    grid = [[0] * CELL for _ in range(CELL)]
    for x0, y0, x1, y1, name in paints:
        _paint(grid, x0, y0, x1, y1, CID[name])
    obj = _surface_doc(
        [{"x": 0, "y": 0, "runs": _runs_from_grid(grid)}],
        map_id=map_id,
        mode=mode)
    _write_json(path, obj)
    return obj


def _unknown_surfaces(path, map_id="topo", mode="full"):
    obj = _surface_doc(
        [{"x": 0, "y": 0, "runs": [[0, SQUARES, CID["unknown"]]]}],
        map_id=map_id,
        mode=mode)
    _write_json(path, obj)
    return obj


def _expect_error(fn, needle):
    try:
        fn()
    except M.AuditError as exc:
        msg = str(exc)
        assert needle in msg, "expected %r in %r" % (needle, msg)
        return
    raise AssertionError("expected AuditError containing %r" % needle)


def _scene_paths(root, mode="full"):
    xml = root / "streets.xml"
    surfaces = root / "surfaces.json"
    # corridor 連接 Side/Top 兩個不同 segment；不是沿 Test St 平行的既有路肩。
    _write_streets(xml, [
        ("Test St", 6, [(10.0, 10.0), (10.0, 80.0)]),
        ("Side St", 6, [(10.0, 80.0), (120.0, 80.0)]),
        ("Top St", 6, [(10.0, 136.0), (30.0, 136.0)]),
    ])
    _write_surfaces(surfaces, [
        (16, 88, 19, 128, "dirt-candidate"),      # 狹長 missing-road extension
        (100, 100, 139, 139, "dirt-candidate"),   # 大 field
        (160, 160, 189, 189, "paved"),            # 庭院實心塊
        (200, 10, 200, 50, "paved"),              # 1 格寬 curb
        (40, 100, 89, 159, "unknown"),            # 建築／木地板
        (210, 210, 250, 250, "natural"),          # 大面積 natural
    ], map_id="corridor-field", mode=mode)
    return xml, surfaces


def test_malformed_schema_version(tmp_path=None):
    root = _root(tmp_path)
    xml = root / "s.xml"
    surfaces = root / "u.json"
    _write_streets(xml, [("A", 6, [(0.0, 0.0), (10.0, 0.0)])])
    obj = _surface_doc([{"x": 0, "y": 0, "runs": [[0, SQUARES, 0]]}])
    obj["schemaVersion"] = 2
    _write_json(surfaces, obj)
    _expect_error(lambda: M.audit(xml, surfaces), "schemaVersion")


def test_malformed_class_table(tmp_path=None):
    root = _root(tmp_path)
    xml = root / "s.xml"
    surfaces = root / "u.json"
    _write_streets(xml, [("A", 6, [(0.0, 0.0), (10.0, 0.0)])])
    obj = _surface_doc([{"x": 0, "y": 0, "runs": [[0, SQUARES, 0]]}])
    obj["classes"] = ["unknown", "paved", "gravel", "dirt", "natural"]
    _write_json(surfaces, obj)
    _expect_error(lambda: M.audit(xml, surfaces), "class table")


def test_malformed_rle_gap_overlap_range(tmp_path=None):
    root = _root(tmp_path)
    xml = root / "s.xml"
    _write_streets(xml, [("A", 6, [(0.0, 0.0), (10.0, 0.0)])])

    def doc(runs):
        return _surface_doc([{"x": 0, "y": 0, "runs": runs}], map_id="x")

    gap = root / "gap.json"
    _write_json(gap, doc([[0, 10, 0], [20, SQUARES - 20, 0]]))
    _expect_error(lambda: M.audit(xml, gap), "RLE gap")

    overlap = root / "overlap.json"
    _write_json(overlap, doc([[0, 20, 0], [10, SQUARES - 10, 0]]))
    _expect_error(lambda: M.audit(xml, overlap), "RLE overlap")

    oob = root / "oob.json"
    _write_json(oob, doc([[0, SQUARES, 9]]))
    _expect_error(lambda: M.audit(xml, oob), "out of range")


def test_surface_source_mismatches(tmp_path=None):
    root = _root(tmp_path)
    xml = root / "s.xml"
    surfaces = root / "u.json"
    _write_streets(xml, [("A", 6, [(0.0, 0.0), (10.0, 0.0)])])
    base = _surface_doc([{"x": 0, "y": 0, "runs": [[0, SQUARES, 0]]}])

    def clone():
        return json.loads(json.dumps(base))

    empty = clone()
    empty["cells"] = []
    _write_json(surfaces, empty)
    _expect_error(lambda: M.audit(xml, surfaces), "非空")

    bad_count = clone()
    bad_count["source"]["scope"]["selectedCellCount"] = 2
    _write_json(surfaces, bad_count)
    _expect_error(lambda: M.audit(xml, surfaces), "selectedCellCount")

    bad_bounds = clone()
    bad_bounds["source"]["scope"]["bounds"] = [0, 0, 1, 0]
    _write_json(surfaces, bad_bounds)
    _expect_error(lambda: M.audit(xml, surfaces), "cells bounds")

    bad_manifest = clone()
    bad_manifest["source"]["inputs"][0]["cells"] = [
        [1, 0, "1_0.lotheader", "world_1_0.lotpack"]]
    _write_json(surfaces, bad_manifest)
    _expect_error(lambda: M.audit(xml, surfaces), "top-level cells")

    bad_priority = clone()
    bad_priority["source"]["inputs"] = [
        {"priority": 1, "layer": "high", "cells": [
            [0, 0, "0_0.lotheader", "world_0_0.lotpack"]]},
        {"priority": 0, "layer": "low", "cells": [
            [0, 0, "0_0.lotheader", "world_0_0.lotpack"]]},
    ]
    _write_json(surfaces, bad_priority)
    _expect_error(lambda: M.audit(xml, surfaces), "priority")

    bad_name = clone()
    bad_name["source"]["inputs"][0]["cells"][0][3] = "wrong.lotpack"
    _write_json(surfaces, bad_name)
    _expect_error(lambda: M.audit(xml, surfaces), "lotpack")


def test_surface_schema_work_limits():
    assert M.MAX_SURFACE_CELLS == 65536
    assert (M.MIN_CELL_COORD, M.MAX_CELL_COORD) == (-128, 127)
    assert M.MAX_SOURCE_INPUTS == 1024
    assert M.MAX_SOURCE_CELL_ROWS == 65536
    cell = {"x": 0, "y": 0, "runs": [[0, SQUARES, CID["unknown"]]]}

    too_many_cells = {
        "schemaVersion": 1,
        "mapId": "too-many-cells",
        "cellSize": CELL,
        "classes": CLASSES,
        "source": {},
        "cells": [cell] * (M.MAX_SURFACE_CELLS + 1),
    }
    _expect_error(
        lambda: M.load_surfaces(M.dumps_canonical(
            too_many_cells).encode("utf-8")),
        "cells 最多 65536，得到 65537")

    manifest_doc = _surface_doc([cell], map_id="too-many-manifest")
    manifest_row = manifest_doc["source"]["inputs"][0]["cells"][0]
    manifest_doc["source"]["inputs"][0]["cells"] = [
        manifest_row] * (M.MAX_SOURCE_CELL_ROWS + 1)
    _expect_error(
        lambda: M.load_surfaces(M.dumps_canonical(
            manifest_doc).encode("utf-8")),
        "source.inputs cell rows 最多 65536，得到 65537")

    inputs_doc = _surface_doc([cell], map_id="too-many-inputs")
    input_row = inputs_doc["source"]["inputs"][0]
    inputs_doc["source"]["inputs"] = [
        input_row] * (M.MAX_SOURCE_INPUTS + 1)
    _expect_error(
        lambda: M.load_surfaces(M.dumps_canonical(
            inputs_doc).encode("utf-8")),
        "source.inputs 最多 1024，得到 1025")

    coord_doc = _surface_doc([cell], map_id="bad-cell-coordinate")
    coord_doc["cells"][0]["x"] = 128
    _expect_error(
        lambda: M.load_surfaces(M.dumps_canonical(
            coord_doc).encode("utf-8")),
        "cell.x 必須介於 -128..127")
    cell["x"] = 0

    region_doc = _surface_doc([cell], map_id="bad-region", mode="region")
    region_doc["source"]["scope"]["requestedRegion"][0] = -129
    _expect_error(
        lambda: M.load_surfaces(M.dumps_canonical(
            region_doc).encode("utf-8")),
        "source.scope.requestedRegion[0] 必須介於 -128..127")


def test_file_size_and_text_limits(tmp_path=None):
    assert M.MAX_STREETS_XML_BYTES == 8 * 1024 * 1024
    assert M.MAX_SURFACES_JSON_BYTES == 64 * 1024 * 1024
    assert M.MAX_TEXT_CHARS == 1024
    root = _root(tmp_path)
    xml = root / "valid.xml"
    surfaces = root / "valid.json"
    _write_streets(xml, [("A", 1, [(0.0, 0.0), (1.0, 0.0)])])
    _unknown_surfaces(surfaces)

    large_xml = root / "large.xml"
    with large_xml.open("wb") as handle:
        handle.seek(M.MAX_STREETS_XML_BYTES)
        handle.write(b"x")
    _expect_error(
        lambda: M.audit(large_xml, surfaces),
        "streets XML 檔案不得超過 8388608 bytes")

    large_surfaces = root / "large.json"
    with large_surfaces.open("wb") as handle:
        handle.seek(M.MAX_SURFACES_JSON_BYTES)
        handle.write(b"x")
    _expect_error(
        lambda: M.audit(xml, large_surfaces),
        "surfaces JSON 檔案不得超過 67108864 bytes")

    long_name = ("N" * (M.MAX_TEXT_CHARS + 1)).encode("ascii")
    name_xml = (
        b'<streets version="1"><street name="' + long_name
        + b'" width="1"><points/></street></streets>')
    _expect_error(
        lambda: M.parse_streets(name_xml),
        "street[0].name 不得超過 1024 chars")

    cell = {"x": 0, "y": 0, "runs": [[0, SQUARES, CID["unknown"]]]}
    map_doc = _surface_doc([cell], map_id="M" * (M.MAX_TEXT_CHARS + 1))
    _expect_error(
        lambda: M.load_surfaces(M.dumps_canonical(map_doc).encode("utf-8")),
        "mapId 不得超過 1024 chars")

    pz_doc = _surface_doc([cell], map_id="text-pz")
    pz_doc["source"]["pzBuild"] = "P" * (M.MAX_TEXT_CHARS + 1)
    _expect_error(
        lambda: M.load_surfaces(M.dumps_canonical(pz_doc).encode("utf-8")),
        "source.pzBuild 不得超過 1024 chars")

    layer_doc = _surface_doc([cell], map_id="text-layer")
    layer_doc["source"]["inputs"][0]["layer"] = (
        "L" * (M.MAX_TEXT_CHARS + 1))
    _expect_error(
        lambda: M.load_surfaces(M.dumps_canonical(layer_doc).encode("utf-8")),
        "source.inputs[0].layer 不得超過 1024 chars")

    filename_doc = _surface_doc([cell], map_id="text-filename")
    filename_doc["source"]["inputs"][0]["cells"][0][2] = (
        "F" * (M.MAX_TEXT_CHARS + 1))
    _expect_error(
        lambda: M.load_surfaces(M.dumps_canonical(
            filename_doc).encode("utf-8")),
        "source.inputs[0].cells[0][2] 不得超過 1024 chars")


def test_malformed_xml(tmp_path=None):
    root = _root(tmp_path)
    surfaces = root / "u.json"
    _unknown_surfaces(surfaces)

    malformed = [
        ("root.xml", b'<world version="1"></world>\n', "streets"),
        ("ver.xml", b'<streets version="2"></streets>\n', "version"),
        ("unrec.xml", b'<streets version="1"><foo/></streets>\n', "unrecognised"),
        ("missing-x.xml", b'<streets version="1"><street width="6"><points>'
         b'<point y="1"/></points></street></streets>\n', "缺少 x"),
        ("nan.xml", b'<streets version="1"><street width="6"><points>'
         b'<point x="NaN" y="1"/></points></street></streets>\n', "有限"),
        ("width-zero.xml", b'<streets version="1"><street width="0"><points/>'
         b'</street></streets>\n', "1..64"),
        ("width-large.xml", b'<streets version="1"><street width="65"><points/>'
         b'</street></streets>\n', "1..64"),
        ("width-float.xml", b'<streets version="1"><street width="6.5"><points/>'
         b'</street></streets>\n', "整數"),
        ("duplicate-points.xml", b'<streets version="1"><street width="6">'
         b'<points/><points/></street></streets>\n', "恰有一個 points"),
        ("unknown-point.xml", b'<streets version="1"><street width="6"><points>'
         b'<foo/></points></street></streets>\n', "unrecognised"),
    ]
    for name, payload, needle in malformed:
        path = root / name
        path.write_bytes(payload)
        _expect_error(lambda path=path: M.audit(path, surfaces), needle)


def test_street_parser_work_limits():
    assert M.MAX_STREETS == 65536
    assert M.MAX_POINTS_PER_STREET == 4096
    assert M.MAX_TOTAL_SEGMENTS == 16384
    assert M.MAX_TOTAL_PROBES == 8000000
    assert M.MAX_SEGMENT_LENGTH == 16384
    assert (M.MIN_STREET_WIDTH, M.MAX_STREET_WIDTH) == (1, 64)
    assert (M.MIN_POINT_COORD, M.MAX_POINT_COORD) == (-32768.0, 32767.5)

    def error_message(payload):
        try:
            M.parse_streets(payload)
        except M.AuditError as exc:
            return str(exc)
        raise AssertionError("expected AuditError")

    street = b'<street width="1"><points/></street>'
    too_many_streets = (
        b'<streets version="1">' + street * (M.MAX_STREETS + 1)
        + b'</streets>')
    assert error_message(too_many_streets) == (
        "streets 最多 65536 個 street，得到 65537")

    point = b'<point x="0" y="0"/>'
    too_many_points = (
        b'<streets version="1"><street width="1"><points>'
        + point * (M.MAX_POINTS_PER_STREET + 1)
        + b'</points></street></streets>')
    assert error_message(too_many_points) == (
        "street[0].points 最多 4096，得到 4097")
    max_point_street = (
        b'<street width="1"><points>'
        + point * M.MAX_POINTS_PER_STREET
        + b'</points></street>')
    six_point_street = (
        b'<street width="1"><points>' + point * 6
        + b'</points></street>')
    too_many_segments = (
        b'<streets version="1">' + max_point_street * 4
        + six_point_street + b'</streets>')
    assert error_message(too_many_segments) == (
        "streets total segments 最多 16384，得到 16385")
    alternating_points = b"".join(
        b'<point x="%d" y="0"/>' % (
            0 if index % 2 == 0 else M.MAX_SEGMENT_LENGTH)
        for index in range(164))
    too_many_probes = (
        b'<streets version="1"><street width="1"><points>'
        + alternating_points + b'</points></street></streets>')
    expected_probes = 163 * 3 * (M.MAX_SEGMENT_LENGTH + 1)
    assert error_message(too_many_probes) == (
        "streets total probes 最多 8000000，得到 %d" % expected_probes)

    coordinate_bounds = (
        b'<streets version="1">'
        b'<street width="1"><points><point x="-32768" y="-32768"/>'
        b'</points></street>'
        b'<street width="1"><points><point x="32767.5" y="32767.5"/>'
        b'</points></street></streets>')
    assert len(M.parse_streets(coordinate_bounds)) == 2
    below = coordinate_bounds.replace(b'x="-32768"', b'x="-32768.5"')
    above = coordinate_bounds.replace(b'y="32767.5"', b'y="32768"')
    assert error_message(below) == (
        "street[0].point[0].x 必須介於 -32768..32767.5")
    assert error_message(above) == (
        "street[1].point[0].y 必須介於 -32768..32767.5")

    exact_limit = (
        b'<streets version="1"><street width="64"><points>'
        b'<point x="0" y="0"/><point x="16384" y="0"/>'
        b'</points></street></streets>')
    assert M.parse_streets(exact_limit)[0]["pts"][-1] == (16384.0, 0.0)
    overlong = exact_limit.replace(b'x="16384"', b'x="16385"')
    expected = "street[0].segment[0] 長度不得超過 16384"
    assert error_message(overlong) == expected
    assert error_message(overlong) == expected


def test_corridor_vs_field_and_negatives(tmp_path=None):
    root = _root(tmp_path)
    xml, surfaces = _scene_paths(root)
    report = M.audit(xml, surfaces)
    accepted = [c for c in report["candidates"] if c["accepted"]]
    rejected = [c for c in report["candidates"] if not c["accepted"]]
    assert len(accepted) == 1, "corridor 必須恰好一條 accepted，得到 %r" % [
        (c["id"], c["bbox"], c["rejectionReasons"]) for c in report["candidates"]
    ]
    corridor = accepted[0]
    assert corridor["length"] >= 32
    assert 2 <= corridor["widthMedian"] <= 8
    assert corridor["coverage"] >= 0.8
    assert corridor["id"] == "c:" + corridor["evidenceHash"]
    assert corridor["parallelToGraphRatio"] < 0.8
    assert corridor["connection"]["nearestSegment0Id"] is not None
    assert corridor["connection"]["endsWithin8"] == 2
    assert not corridor["connection"]["sameSegment"]
    assert corridor["surfacePurity"] == 1.0
    bb = corridor["bbox"]
    assert bb["x0"] <= 19 and bb["x1"] >= 16
    assert bb["y0"] <= 88 and bb["y1"] >= 128

    def overlaps(c, x0, y0, x1, y1):
        b = c["bbox"]
        return not (b["x1"] < x0 or b["x0"] > x1 or b["y1"] < y0 or b["y0"] > y1)

    field_hits = [c for c in rejected if overlaps(c, 100, 100, 139, 139)]
    assert field_hits, "field 必須被分析且拒絕，不得 hardcode 成省略"
    assert any(
        "field" in c["rejectionReasons"] or "noLongAxis" in c["rejectionReasons"]
        or "medianWidth" in c["rejectionReasons"]
        for c in field_hits
    )
    assert not any(c["accepted"] and overlaps(c, 100, 100, 139, 139) for c in report["candidates"])
    assert not any(c["accepted"] and overlaps(c, 160, 160, 189, 189) for c in report["candidates"])
    assert not any(c["accepted"] and overlaps(c, 200, 10, 200, 50) for c in report["candidates"])
    assert not any(overlaps(c, 40, 100, 89, 159) for c in report["candidates"])
    assert not any(overlaps(c, 210, 210, 250, 250) for c in report["candidates"])
    curb_hits = [c for c in rejected if overlaps(c, 200, 10, 200, 50)]
    if curb_hits:
        assert all("medianWidth" in c["rejectionReasons"] for c in curb_hits)


def test_coverage_spans_remove_existing_street(tmp_path=None):
    root = _root(tmp_path)
    xml = root / "covered.xml"
    surfaces = root / "covered.json"
    _write_streets(xml, [
        ("Already Mapped", 6, [(50.0, 10.0), (50.0, 90.0)]),
    ])
    _write_surfaces(surfaces, [
        (47, 20, 52, 80, "paved"),
    ], map_id="covered")
    report = M.audit(xml, surfaces)
    analysis = report["candidateAnalysis"]
    assert analysis["pixelCount"] == 6 * 61
    assert analysis["maskedPixelCount"] == analysis["pixelCount"]
    assert analysis["uncoveredPixelCount"] == 0
    assert report["candidates"] == []


def test_parallel_residual_rejected(tmp_path=None):
    root = _root(tmp_path)
    xml = root / "parallel.xml"
    surfaces = root / "parallel.json"
    _write_streets(xml, [
        ("Mapped Parallel", 6, [(10.0, 10.0), (10.0, 90.0)]),
    ])
    _write_surfaces(surfaces, [
        (16, 20, 19, 60, "dirt-candidate"),
    ], map_id="parallel-residual")
    report = M.audit(xml, surfaces)
    candidate = next(
        item for item in report["candidates"]
        if item["bbox"] == {"x0": 16, "y0": 20, "x1": 19, "y1": 60})
    assert not candidate["accepted"]
    assert candidate["parallelToGraphRatio"] == 1.0
    assert candidate["maxGraphDistance"] <= 8.0
    assert "parallelResidual" in candidate["rejectionReasons"]
    assert candidate["connection"]["sameSegment"]
    assert candidate["connection"]["endsWithin8"] == 2
    assert "sameAttachment" in candidate["rejectionReasons"]


def test_parallel_profile_checks_all_nearby_segments():
    streets = [
        {"name": "Parallel", "width": 1, "pts": [(0.0, 7.0), (40.0, 7.0)]},
        {"name": "Closer Spur", "width": 1, "pts": [(20.0, -1.0), (20.0, 1.0)]},
    ]
    graph = M.graph_segments(streets, (-10, -10, 50, 20))
    polyline = [(0.0, 0.0), (20.0, 0.0), (40.0, 0.0)]
    _, nearest_middle = M.nearest_graph_segment(20.0, 0.0, graph)
    assert nearest_middle["id"] == "s:1:0"
    ratio, _ = M.graph_parallel_profile(polyline, graph)
    assert ratio == 1.0


def test_surface_impure_rejected(tmp_path=None):
    root = _root(tmp_path)
    xml = root / "surface-impure.xml"
    surfaces = root / "surface-impure.json"
    _write_streets(xml, [
        ("Start", 1, [(32.5, 30.0), (32.5, 50.0)]),
        ("End", 1, [(139.5, 30.0), (139.5, 50.0)]),
    ])
    _write_surfaces(surfaces, [
        (40, 40, 85, 43, "gravel"),
        (86, 40, 131, 43, "dirt-candidate"),
    ], map_id="surface-impure")
    candidate = M.audit(xml, surfaces)["candidates"][0]
    assert candidate["connection"]["endsWithin8"] == 2
    assert not candidate["connection"]["sameSegment"]
    assert candidate["dominantSurface"] == "gravel"
    assert candidate["surfacePurity"] == 0.5
    assert not candidate["accepted"]
    assert "surfaceImpure" in candidate["rejectionReasons"]


def test_global_retention_budget_degrades_deterministically(tmp_path=None):
    root = _root(tmp_path)
    xml = root / "global-budget.xml"
    surfaces = root / "global-budget.json"
    _write_streets(xml, [
        ("Left Start", 1, [(30.0, 12.5), (50.0, 12.5)]),
        ("Left End", 1, [(30.0, 227.5), (50.0, 227.5)]),
        ("Right Start", 1, [(90.0, 12.5), (110.0, 12.5)]),
        ("Right End", 1, [(90.0, 227.5), (110.0, 227.5)]),
    ])
    _write_surfaces(surfaces, [
        (40, 20, 43, 219, "gravel"),
        (100, 20, 103, 219, "dirt-candidate"),
    ], map_id="global-budget")
    report = M.audit(xml, surfaces, max_candidate_pixels=1000)
    analysis = report["candidateAnalysis"]
    assert analysis["globalRetentionBudgetPixels"] == 1000
    assert analysis["componentLimitedComponentCount"] == 0
    assert analysis["globalBudgetLimitedComponentCount"] == 1
    assert analysis["peakRetainedDetailedPixelCount"] == 1000
    assert analysis["peakRetainedDetailedSpanCount"] == 250
    assert analysis["retainedDetailedPixelCount"] == 4 * 200
    assert analysis["retainedDetailedSpanCount"] == 200
    assert len(report["candidates"]) == 2
    assert sum(item["analysisStatus"] == "aggregate"
               for item in report["candidates"]) == 1
    assert sum(item["accepted"] for item in report["candidates"]) == 1
    aggregate = next(
        item for item in report["candidates"]
        if item["analysisStatus"] == "aggregate")
    assert aggregate["connection"]["endsWithin8"] < 2
    assert "unverifiedTerminus" in aggregate["rejectionReasons"]
    assert M.dumps_canonical(report) == M.dumps_canonical(
        M.audit(xml, surfaces, max_candidate_pixels=1000))


def test_dead_previous_row_releases_global_budget(tmp_path=None):
    root = _root(tmp_path)
    xml = root / "row-release.xml"
    surfaces = root / "row-release.json"
    _write_streets(xml, [
        ("Far", 1, [(250.0, 240.0), (250.0, 250.0)]),
    ])
    _write_surfaces(surfaces, [
        (20, 40, 119, 40, "gravel"),
        (120, 41, 219, 41, "dirt-candidate"),
    ], map_id="row-release")
    report = M.audit(xml, surfaces, max_candidate_pixels=100)
    analysis = report["candidateAnalysis"]
    assert len(report["candidates"]) == 2
    assert all(item["area"] == 100 for item in report["candidates"])
    assert all(item["analysisStatus"] == "detailed"
               for item in report["candidates"])
    assert analysis["componentLimitedComponentCount"] == 0
    assert analysis["globalBudgetLimitedComponentCount"] == 0
    assert analysis["peakRetainedDetailedPixelCount"] == 100
    assert analysis["retainedDetailedPixelCount"] == 200


def test_candidate_polyline_point_limit():
    assert M.MAX_CANDIDATE_POLYLINE_POINTS == 8192

    def component(length):
        work = {
            "globalRetentionBudgetPixels": M.MAX_CANDIDATE_PIXELS,
            "currentRetainedDetailedPixelCount": 0,
            "currentRetainedDetailedSpanCount": 0,
            "peakRetainedDetailedPixelCount": 0,
            "peakRetainedDetailedSpanCount": 0,
        }
        item = M._SpanComponent(0)
        item.add_span(
            0, 0, length, CID["dirt-candidate"],
            M.MAX_CANDIDATE_PIXELS, work)
        return item

    exact = M.profile_component(
        component(M.MAX_CANDIDATE_POLYLINE_POINTS))
    assert exact["status"] == "detailed"
    assert len(exact["polyline"]) == M.MAX_CANDIDATE_POLYLINE_POINTS

    over_component = component(M.MAX_CANDIDATE_POLYLINE_POINTS + 1)
    over = M.profile_component(over_component)
    assert over["status"] == "aggregate"
    assert len(over["polyline"]) == 2

    class CandidateSurface:
        @staticmethod
        def at(_x, _y):
            return CID["dirt-candidate"]

    end_x = M.MAX_CANDIDATE_POLYLINE_POINTS
    graph = M.graph_segments([
        {"name": "Start", "width": 1,
         "pts": [(-8.0, -10.0), (-8.0, 10.0)]},
        {"name": "End", "width": 1,
         "pts": [(end_x + 8.0, -10.0), (end_x + 8.0, 10.0)]},
    ], (-16, -16, end_x + 16, 16))
    analyzed = M.analyze_component(
        over_component, CandidateSurface(), graph,
        "surface-fingerprint", "xml-sha")
    assert analyzed["analysisStatus"] == "aggregate"
    assert "storageLimit" in analyzed["rejectionReasons"]


def test_candidate_work_caps_fail_closed(tmp_path=None):
    assert M.MAX_COMPONENTS == 50000
    assert M.MAX_REPORTED_CANDIDATES == 10000
    assert M.MAX_CANDIDATE_GRAPH_WORK == 100000000
    assert M.MAX_CANDIDATE_GRAPH_BUCKET_REFS == 250000
    assert M.MAX_TOTAL_PROFILE_WORK == 100000000
    assert M.MAX_TOTAL_CANDIDATE_POLYLINE_POINTS == 2000000
    assert (M.MAX_REPORTED_CANDIDATES
            * M.MAX_CANDIDATE_POLYLINE_POINTS
            > M.MAX_TOTAL_CANDIDATE_POLYLINE_POINTS)
    root = _root(tmp_path)
    xml = root / "candidate-caps.xml"
    surfaces = root / "candidate-caps.json"
    _write_streets(xml, [
        ("G0", 1, [(200.0, 0.0), (200.0, 20.0)]),
        ("G1", 1, [(210.0, 0.0), (210.0, 20.0)]),
        ("G2", 1, [(220.0, 0.0), (220.0, 20.0)]),
        ("G3", 1, [(230.0, 0.0), (230.0, 20.0)]),
    ])
    _write_surfaces(surfaces, [
        (20, 20, 23, 23, "gravel"),
        (40, 20, 43, 23, "dirt-candidate"),
        (60, 20, 63, 23, "paved"),
    ], map_id="candidate-caps")
    real_components = M.MAX_COMPONENTS
    real_reported = M.MAX_REPORTED_CANDIDATES
    real_graph_work = M.MAX_CANDIDATE_GRAPH_WORK
    real_graph_bucket_refs = M.MAX_CANDIDATE_GRAPH_BUCKET_REFS
    real_profile_work = M.MAX_TOTAL_PROFILE_WORK
    real_polyline_points = M.MAX_TOTAL_CANDIDATE_POLYLINE_POINTS
    try:
        diagonal = [{
            "name": "Diagonal", "width": 1,
            "pts": [(0.0, 0.0), (16000.0, 16000.0)],
        }]
        graph = M.graph_segments(diagonal, (0, 0, 16000, 16000))
        assert graph["bucketReferenceCount"] < 5000
        M.MAX_CANDIDATE_GRAPH_BUCKET_REFS = 10
        _expect_error(
            lambda: M.graph_segments(
                diagonal, (0, 0, 16000, 16000)),
            "candidate graph bucket references")
        M.MAX_CANDIDATE_GRAPH_BUCKET_REFS = real_graph_bucket_refs

        M.MAX_COMPONENTS = 2
        _expect_error(
            lambda: M.audit(xml, surfaces), "candidate components")
        M.MAX_COMPONENTS = real_components

        M.MAX_REPORTED_CANDIDATES = 2
        _expect_error(
            lambda: M.audit(xml, surfaces), "reported candidates")
        M.MAX_REPORTED_CANDIDATES = real_reported
        M.MAX_TOTAL_PROFILE_WORK = 31
        _expect_error(
            lambda: M.audit(xml, surfaces), "candidate profile work")
        M.MAX_TOTAL_PROFILE_WORK = real_profile_work

        M.MAX_TOTAL_CANDIDATE_POLYLINE_POINTS = 7
        _expect_error(
            lambda: M.audit(xml, surfaces), "candidate polyline points")
        M.MAX_TOTAL_CANDIDATE_POLYLINE_POINTS = real_polyline_points


        M.MAX_CANDIDATE_GRAPH_WORK = 5
        _expect_error(
            lambda: M.audit(xml, surfaces), "candidate graph work")
    finally:
        M.MAX_COMPONENTS = real_components
        M.MAX_REPORTED_CANDIDATES = real_reported
        M.MAX_CANDIDATE_GRAPH_WORK = real_graph_work
        M.MAX_CANDIDATE_GRAPH_BUCKET_REFS = real_graph_bucket_refs
        M.MAX_TOTAL_PROFILE_WORK = real_profile_work
        M.MAX_TOTAL_CANDIDATE_POLYLINE_POINTS = real_polyline_points


def test_cross_cell_row_span_components(tmp_path=None):
    root = _root(tmp_path)
    xml = root / "cross-cell.xml"
    surfaces = root / "cross-cell.json"
    _write_streets(xml, [
        ("Horizontal Start", 1, [(238.0, 30.0), (238.0, 50.0)]),
        ("Horizontal End", 1, [(354.0, 30.0), (354.0, 50.0)]),
        ("Vertical Start", 1, [(30.0, 238.0), (50.0, 238.0)]),
        ("Vertical End", 1, [(30.0, 354.0), (50.0, 354.0)]),
    ])
    cells = [
        _surface_cell(0, 0, [
            (246, 40, 255, 43, "gravel"),
            (40, 246, 43, 255, "gravel"),
        ]),
        _surface_cell(1, 0, [
            (0, 40, 90, 43, "dirt-candidate"),
        ]),
        _surface_cell(0, 1, [
            (40, 0, 43, 90, "dirt-candidate"),
        ]),
        _surface_cell(1, 1, []),
    ]
    _write_json(surfaces, _surface_doc(cells, map_id="cross-cell"))

    first = M.audit(xml, surfaces)
    second = M.audit(xml, surfaces)
    assert M.dumps_canonical(first) == M.dumps_canonical(second)
    sample_ids = {
        sample["id"] for sample in first["streetSamples"]
        if not sample["railroad"]
    }
    accepted = [item for item in first["candidates"] if item["accepted"]]
    assert len(accepted) == 2, [
        (item["bbox"], item["rejectionReasons"])
        for item in first["candidates"]
    ]
    assert any(item["bbox"]["x0"] < 256 <= item["bbox"]["x1"]
               for item in accepted)
    assert any(item["bbox"]["y0"] < 256 <= item["bbox"]["y1"]
               for item in accepted)
    for item in accepted:
        assert item["analysisStatus"] == "detailed"
        assert item["surfaceCounts"]["gravel"] > 0
        assert item["surfaceCounts"]["dirt-candidate"] > 0
        # 相鄰 candidate classes 是同一道路的 surface transition，不是 CCL 邊界。
        assert item["surfaceCounts"]["gravel"] == 10 * 4
        assert item["surfaceCounts"]["dirt-candidate"] == 91 * 4
        assert item["dominantSurface"] == "dirt-candidate"
        assert item["surfacePurity"] == M.r3((91 * 4) / float(101 * 4))
        assert item["id"] == "c:" + item["evidenceHash"]
        assert item["connection"]["nearestSegment0Id"] in sample_ids
        assert item["connection"]["nearestSegment1Id"] in sample_ids
        assert item["connection"]["endsWithin8"] == 2
        assert not item["connection"]["sameSegment"]


def test_large_field_and_courtyard_rejected(tmp_path=None):
    root = _root(tmp_path)
    xml = root / "aggregate.xml"
    surfaces = root / "aggregate.json"
    _write_streets(xml, [
        ("Courtyard Link", 1, [(32.0, 30.0), (32.0, 130.0)]),
    ])
    courtyard = [
        (40, 40, 119, 43, "paved"),
        (40, 116, 119, 119, "paved"),
        (40, 44, 43, 115, "paved"),
        (116, 44, 119, 115, "paved"),
    ]
    cells = [
        _surface_cell(0, 0, courtyard),
        _surface_cell(1, 0, []),
        _surface_cell(2, 0, [
            (0, 0, 255, 255, "dirt-candidate"),
        ]),
    ]
    _write_json(surfaces, _surface_doc(cells, map_id="aggregate-rejections"))

    report = M.audit(xml, surfaces, max_candidate_pixels=4096)
    analysis = report["candidateAnalysis"]
    assert analysis["status"] == "ok"
    assert analysis["storageLimitedComponentCount"] == 1
    assert analysis["aggregateCandidateCount"] == 1
    courtyard_hit = next(
        item for item in report["candidates"]
        if item["bbox"] == {"x0": 40, "y0": 40, "x1": 119, "y1": 119})
    assert not courtyard_hit["accepted"]
    assert "courtyard" in courtyard_hit["rejectionReasons"]
    field = next(
        item for item in report["candidates"]
        if item["bbox"]["x0"] == 2 * CELL)
    assert field["analysisStatus"] == "aggregate"
    assert not field["accepted"]
    assert "storageLimit" in field["rejectionReasons"]
    assert ("field" in field["rejectionReasons"]
            or "noLongAxis" in field["rejectionReasons"])
    assert M.dumps_canonical(report) == M.dumps_canonical(
        M.audit(xml, surfaces, max_candidate_pixels=4096))


def test_byte_identical_and_preview(tmp_path=None):
    root = _root(tmp_path)
    xml, surfaces = _scene_paths(root)
    out1 = root / "a.json"
    out2 = root / "b.json"
    preview = root / "p.geojson"
    assert M.main(["--streets", str(xml), "--surfaces", str(surfaces),
                   "--out", str(out1), "--preview", str(preview)]) == 0
    assert M.main(["--streets", str(xml), "--surfaces", str(surfaces),
                   "--out", str(out2)]) == 0
    b1 = out1.read_bytes()
    b2 = out2.read_bytes()
    assert b1 == b2
    assert b1.endswith(b"\n")
    assert b"\r\n" not in b1
    doc = json.loads(b1.decode("utf-8"))
    assert set(doc) >= {
        "source", "surfaceCoverage", "baseline", "topology",
        "streetSamples", "candidateAnalysis", "candidates"}
    assert set(doc["source"]) == {
        "xmlSha256", "surfaceFingerprint", "surfaceSource"}
    surface_doc = json.loads(surfaces.read_text(encoding="utf-8"))
    assert doc["source"]["surfaceSource"] == surface_doc["source"]
    prev = json.loads(preview.read_text(encoding="utf-8"))
    assert prev["type"] == "FeatureCollection"
    assert prev["features"]


def test_evidence_hash_binds_both_input_hashes(tmp_path=None):
    root = _root(tmp_path)
    xml, surfaces = _scene_paths(root)
    base = M.audit(xml, surfaces)

    def evidence_payload(report, item):
        candidate = {
            key: value for key, value in item.items()
            if key not in ("id", "evidenceHash")
        }
        return {
            "version": candidate["evidenceVersion"],
            "source": {
                "surfaceFingerprint": report["source"]["surfaceFingerprint"],
                "xmlSha256": report["source"]["xmlSha256"],
            },
            "candidate": candidate,
        }

    def evidence_hash(report, item):
        return M.hashlib.sha256(M.dumps_canonical(
            evidence_payload(report, item)).encode("utf-8")).hexdigest()

    for item in base["candidates"]:
        assert item["polylineQ2"] == [
            [M.q2(x), M.q2(y)] for x, y in item["polyline"]]
        rebuilt = evidence_hash(base, item)
        assert rebuilt == item["evidenceHash"]
        assert item["id"] == "c:" + rebuilt
    original = next(
        item for item in base["candidates"] if item["accepted"])
    tamper_values = {
        "accepted": not original["accepted"],
        "analysisStatus": "aggregate",
        "boundaryTruncated": not original["boundaryTruncated"],
        "rejectionReasons": list(original["rejectionReasons"]) + ["tampered"],
    }
    for key, value in tamper_values.items():
        tampered = json.loads(M.dumps_canonical(original))
        tampered[key] = value
        assert evidence_hash(base, tampered) != original["evidenceHash"]

    limited = M.audit(xml, surfaces, max_candidate_pixels=1)
    rejected_aggregate = next(
        item for item in limited["candidates"]
        if item["analysisStatus"] == "aggregate" and not item["accepted"])
    tampered = json.loads(M.dumps_canonical(rejected_aggregate))
    tampered["accepted"] = True
    tampered["analysisStatus"] = "detailed"
    tampered["boundaryTruncated"] = False
    tampered["rejectionReasons"] = []
    assert evidence_hash(limited, tampered) != rejected_aggregate["evidenceHash"]

    def corridor(report):
        return next(
            item for item in report["candidates"]
            if item["bbox"] == {"x0": 16, "y0": 88, "x1": 19, "y1": 128})

    renamed_xml = root / "renamed.xml"
    renamed_xml.write_bytes(
        xml.read_bytes().replace(b"Test St", b"Test Rd"))
    renamed = M.audit(renamed_xml, surfaces)
    assert base["source"]["surfaceFingerprint"] == renamed["source"][
        "surfaceFingerprint"]
    assert base["source"]["xmlSha256"] != renamed["source"]["xmlSha256"]
    assert corridor(base)["polyline"] == corridor(renamed)["polyline"]
    assert corridor(base)["evidenceHash"] != corridor(renamed)["evidenceHash"]

    changed_surfaces = root / "changed-surfaces.json"
    surface_doc = json.loads(surfaces.read_text(encoding="utf-8"))
    surface_doc["mapId"] = "corridor-field-copy"
    _write_json(changed_surfaces, surface_doc)
    changed = M.audit(xml, changed_surfaces)
    assert base["source"]["xmlSha256"] == changed["source"]["xmlSha256"]
    assert base["source"]["surfaceFingerprint"] != changed["source"][
        "surfaceFingerprint"]
    assert corridor(base)["polyline"] == corridor(changed)["polyline"]
    assert corridor(base)["evidenceHash"] != corridor(changed)["evidenceHash"]


def test_street_sample_ids_unique_for_same_endpoints(tmp_path=None):
    root = _root(tmp_path)
    xml = root / "same-ends.xml"
    surfaces = root / "same-ends.json"
    _write_streets(xml, [
        ("Straight", 1, [(0.0, 0.0), (10.0, 0.0), (20.0, 0.0)]),
        ("Bent", 1, [(0.0, 0.0), (10.0, 10.0), (20.0, 0.0)]),
    ])
    _unknown_surfaces(surfaces)
    report = M.audit(xml, surfaces)
    sample_ids = [sample["id"] for sample in report["streetSamples"]]
    assert sample_ids == ["s:0:0", "s:0:1", "s:1:0", "s:1:1"]
    assert len(sample_ids) == len(set(sample_ids))
    streets = M.parse_streets(xml.read_bytes())
    graph = M.graph_segments(streets, (0, 0, 255, 255))
    assert {segment["id"] for segment in graph["segments"]} == set(sample_ids)


def test_full_region_missing_and_boundary(tmp_path=None):
    root = _root(tmp_path)
    xml, surfaces = _scene_paths(root)
    full = M.audit(xml, surfaces)
    assert full["surfaceCoverage"]["status"] == "full"
    assert full["surfaceCoverage"]["providedCellCount"] == 1
    assert full["candidateAnalysis"]["status"] == "ok"

    xml, surfaces = _scene_paths(root, mode="region")
    partial = M.audit(xml, surfaces)
    assert partial["surfaceCoverage"]["status"] == "partial"
    assert partial["candidateAnalysis"]["status"] == "partial"
    assert partial["source"]["surfaceSource"]["scope"]["mode"] == "region"
    out = root / "partial.json"
    stdout = io.StringIO()
    with contextlib.redirect_stdout(stdout):
        assert M.main([
            "--streets", str(xml), "--surfaces", str(surfaces),
            "--out", str(out)]) == 0
    summary = stdout.getvalue()
    assert "candidateAnalysis=partial" in summary
    assert "surfaceCoverage=partial" in summary

    missing_xml = root / "missing.xml"
    missing_surfaces = root / "missing.json"
    _write_streets(missing_xml, [
        ("Edge", 2, [(-10.0, 10.0), (10.0, 10.0)])])
    _unknown_surfaces(missing_surfaces, mode="region")
    loaded = M.load_surfaces(missing_surfaces.read_bytes())
    index = M.SurfaceIndex(loaded)
    assert index.at(0.0, 0.0) == CID["unknown"]
    assert index.at(-0.1, 0.0) is M.MISSING
    missing = M.audit(missing_xml, missing_surfaces)
    coverage = missing["surfaceCoverage"]
    assert coverage["missingProbeCount"] > 0
    assert coverage["totalProbeCount"] > coverage["missingProbeCount"]
    assert missing["streetSamples"][0]["surface"]["missingCount"] > 0

    boundary_xml = root / "boundary.xml"
    boundary_surfaces = root / "boundary.json"
    _write_streets(boundary_xml, [
        ("Nearby", 1, [(9.0, 10.0), (9.0, 80.0)])])
    _write_surfaces(
        boundary_surfaces,
        [(0, 20, 3, 60, "dirt-candidate")],
        mode="region")
    boundary = M.audit(boundary_xml, boundary_surfaces)
    hits = [candidate for candidate in boundary["candidates"]
            if candidate["bbox"]["x0"] == 0]
    assert hits
    assert all(candidate["boundaryTruncated"] for candidate in hits)
    assert all(not candidate["accepted"] for candidate in hits)
    assert all("boundaryTruncated" in candidate["rejectionReasons"]
               for candidate in hits)


def test_width_p90_always_rejected(tmp_path=None):
    root = _root(tmp_path)
    xml = root / "wide.xml"
    surfaces = root / "wide.json"
    _write_streets(xml, [
        ("Left", 1, [(32.0, 0.0), (32.0, 50.0)]),
        ("Right", 1, [(167.0, 0.0), (167.0, 50.0)]),
    ])
    _write_surfaces(surfaces, [
        (40, 20, 159, 25, "dirt-candidate"),
        (90, 19, 109, 27, "dirt-candidate"),
    ])
    report = M.audit(xml, surfaces)
    hits = [candidate for candidate in report["candidates"]
            if candidate["bbox"]["x0"] <= 40
            and candidate["bbox"]["x1"] >= 159]
    assert len(hits) == 1
    candidate = hits[0]
    assert candidate["widthP90"] > 8
    assert "widthP90" in candidate["rejectionReasons"]
    assert not candidate["accepted"]


def test_path_aliases_and_atomic_write(tmp_path=None):
    root = _root(tmp_path)
    xml, surfaces = _scene_paths(root)
    original_xml = xml.read_bytes()
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        rc = M.main([
            "--streets", str(xml), "--surfaces", str(surfaces),
            "--out", str(xml)])
    assert rc == 2
    assert "path alias" in err.getvalue()
    assert xml.read_bytes() == original_xml

    same = root / "same.json"
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        rc = M.main([
            "--streets", str(xml), "--surfaces", str(surfaces),
            "--out", str(same), "--preview", str(same)])
    assert rc == 2
    assert not same.exists()

    real_replace = M.os.replace
    paired_out = root / "paired.json"
    paired_preview = root / "paired.geojson"
    paired_out.write_bytes(b"old canonical")
    paired_preview.write_bytes(b"old preview")

    def fail_preview_replace(source, destination):
        raise OSError("preview replace fixture")

    M.os.replace = fail_preview_replace
    try:
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = M.main([
                "--streets", str(xml), "--surfaces", str(surfaces),
                "--out", str(paired_out), "--preview", str(paired_preview)])
    finally:
        M.os.replace = real_replace
    assert rc == 2
    assert "preview replace fixture" in err.getvalue()
    assert paired_out.read_bytes() == b"old canonical"
    assert paired_preview.read_bytes() == b"old preview"

    replace_calls = [0]

    def fail_second_replace(source, destination):
        replace_calls[0] += 1
        if replace_calls[0] == 2:
            raise OSError("canonical replace fixture")
        return real_replace(source, destination)

    M.os.replace = fail_second_replace
    try:
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            rc = M.main([
                "--streets", str(xml), "--surfaces", str(surfaces),
                "--out", str(paired_out), "--preview", str(paired_preview)])
    finally:
        M.os.replace = real_replace
    assert rc == 2
    assert "preview 已更新；canonical out 未更新" in err.getvalue()
    assert paired_out.read_bytes() == b"old canonical"
    preview_doc = json.loads(paired_preview.read_text(encoding="utf-8"))
    assert preview_doc["type"] == "FeatureCollection"
    assert not list(root.glob(".*.tmp"))


def test_topology_findings(tmp_path=None):
    root = _root(tmp_path)
    xml = root / "topo.xml"
    surfaces = root / "u.json"
    _unknown_surfaces(surfaces)
    _write_streets(xml, [
        ("", 6, [(0.0, 0.0), (8.0, 0.0)]),
        ("Short", 6, [(1.0, 1.0)]),
        ("Zero", 6, [(5.0, 5.0), (5.0, 5.0), (12.0, 5.0)]),
        ("Dup", 6, [(30.0, 0.0), (40.0, 0.0)]),
        ("Dup", 6, [(30.0, 0.0), (40.0, 0.0)]),
        ("CrossA", 6, [(0.0, 20.0), (20.0, 20.0)]),
        ("CrossB", 6, [(10.0, 10.0), (10.0, 30.0)]),
        ("SelfX", 6, [(50.0, 0.0), (60.0, 10.0), (50.0, 10.0), (60.0, 0.0)]),
        ("NearA", 6, [(80.0, 0.0), (90.0, 0.0)]),
        ("NearB", 6, [(90.0, 3.0), (100.0, 3.0)]),
    ])
    report = M.audit(xml, surfaces)
    kinds = {f["kind"] for f in report["topology"]["findings"]}
    for need in ("emptyName", "short", "zeroLength", "duplicate",
                 "selfIntersection", "crossing", "nearEndpoint"):
        assert need in kinds, "missing finding %s in %r" % (need, kinds)
    assert report["baseline"]["emptyNameCount"] >= 1
    assert report["baseline"]["shortCount"] >= 1
    assert report["baseline"]["zeroLengthCount"] >= 1
    assert report["baseline"]["duplicateCount"] >= 1
    assert "rawExactVertexComponentCount" in report["topology"]
    assert "rawExactVertexComponentSizes" in report["topology"]
    assert "componentCount" not in report["topology"]
    assert set(report["topology"]["work"]) == {
        "bucketReferenceCount", "topologyPairWorkCount",
        "topologyPairScanCount", "endpointWorkCount"}
    assert all(value > 0 for value in report["topology"]["work"].values())


def test_spatial_topology_matches_bruteforce():
    def brute(streets):
        segs = []
        for street_index, street in enumerate(streets):
            pts = street["pts"]
            sid = M.street_sig(pts)
            for seg_index in range(len(pts) - 1):
                segs.append((
                    street_index, seg_index, pts[seg_index],
                    pts[seg_index + 1], sid))
        findings = []
        for first in range(len(segs)):
            ia, ka, a0, a1, sa = segs[first]
            for second in range(first + 1, len(segs)):
                ib, kb, b0, b1, sb = segs[second]
                if ia != ib and M.proper_intersect(a0, a1, b0, b1):
                    findings.append({
                        "kind": "crossing",
                        "id": sa,
                        "streetIndex": ia,
                        "otherStreetIndex": ib,
                        "segA": ka,
                        "segB": kb,
                        "otherId": sb,
                    })
        usable = [
            (index, street["pts"], M.street_sig(street["pts"]))
            for index, street in enumerate(streets)
            if len(street["pts"]) >= 2
        ]
        for street_index, pts, sid in usable:
            for end_slot, end_index in enumerate((0, -1)):
                px, py = pts[end_index]
                best = None
                for other_index, other_pts, other_sid in usable:
                    if street_index == other_index:
                        continue
                    for seg_index in range(len(other_pts) - 1):
                        distance = M.dist_point_seg(
                            px, py,
                            other_pts[seg_index][0], other_pts[seg_index][1],
                            other_pts[seg_index + 1][0],
                            other_pts[seg_index + 1][1])
                        if best is None or distance < best[0]:
                            best = (distance, other_index, other_sid)
                if (best is not None
                        and M.NEAR_ENDPOINT_LO <= best[0] <= M.GATE_CONNECT):
                    findings.append({
                        "kind": "nearEndpoint",
                        "id": sid,
                        "streetIndex": street_index,
                        "end": end_slot,
                        "distance": M.r3(best[0]),
                        "nearStreetIndex": best[1],
                        "nearId": best[2],
                    })
        findings.sort(key=lambda finding: (
            M.KIND_ORDER.get(finding["kind"], 99),
            finding.get("streetIndex", 0),
            finding.get(
                "segIndex", finding.get(
                    "segA", finding.get("end", 0))),
            finding.get("otherStreetIndex", 0),
            finding.get("segB", 0),
            finding.get("id", ""),
        ))
        return findings

    scenes = [[
        {"name": "Boundary H", "width": 1,
         "pts": [(-128.0, 0.0), (128.0, 0.0)]},
        {"name": "Boundary V", "width": 1,
         "pts": [(0.0, -128.0), (0.0, 128.0)]},
        {"name": "Near A", "width": 1,
         "pts": [(190.0, 0.0), (200.0, 0.0)]},
        {"name": "Near B", "width": 1,
         "pts": [(200.0, 3.0), (210.0, 3.0)]},
    ]]
    rng = random.Random(420164)
    for _ in range(100):
        streets = []
        for street_index in range(rng.randint(2, 8)):
            pts = [
                (float(rng.randint(-160, 160)),
                 float(rng.randint(-160, 160)))
                for _ in range(rng.randint(2, 5))
            ]
            streets.append({
                "name": "R%d" % street_index,
                "width": 1,
                "pts": pts,
            })
        scenes.append(streets)
    for streets in scenes:
        actual = [
            finding for finding in M.topology_findings(streets)
            if finding["kind"] in ("crossing", "nearEndpoint")]
        assert actual == brute(streets)


def test_topology_work_caps_fail_closed():
    assert M.MAX_BUCKET_REFERENCES == 250000
    assert M.MAX_TOPOLOGY_PAIR_WORK == 250000
    assert M.MAX_TOPOLOGY_PAIR_SCAN == 1000000
    assert M.MAX_ENDPOINT_WORK == 10000000
    assert M.MAX_TOPOLOGY_FINDINGS == 20000
    real_bucket = M.MAX_BUCKET_REFERENCES
    real_pair = M.MAX_TOPOLOGY_PAIR_WORK
    real_scan = M.MAX_TOPOLOGY_PAIR_SCAN
    real_endpoint = M.MAX_ENDPOINT_WORK
    real_findings = M.MAX_TOPOLOGY_FINDINGS
    try:
        M.MAX_BUCKET_REFERENCES = 1
        _expect_error(lambda: M.topology_findings([{
            "name": "Long", "width": 1,
            "pts": [(0.0, 1.0), (200.0, 1.0)],
        }]), "topology bucket references")
        M.MAX_BUCKET_REFERENCES = real_bucket

        M.MAX_TOPOLOGY_PAIR_WORK = 3
        dense = [
            {"name": "D%d" % index, "width": 1,
             "pts": [(0.0, float(index)), (20.0, float(20 - index))]}
            for index in range(4)
        ]
        _expect_error(
            lambda: M.topology_findings(dense), "topology pair work")
        M.MAX_TOPOLOGY_PAIR_WORK = real_pair
        M.MAX_TOPOLOGY_PAIR_SCAN = 1000
        repeated_long = [
            {"name": "L%d" % index, "width": 1,
             "pts": [(0.0, 1.0), (16000.0, 1.0)]}
            for index in range(100)
        ]
        _expect_error(
            lambda: M.topology_findings(repeated_long),
            "topology pair scan")
        M.MAX_TOPOLOGY_PAIR_SCAN = real_scan

        M.MAX_ENDPOINT_WORK = 2
        nearby = [
            {"name": "A", "width": 1,
             "pts": [(0.0, 0.0), (20.0, 0.0)]},
            {"name": "B", "width": 1,
             "pts": [(0.0, 10.0), (20.0, 10.0)]},
        ]
        _expect_error(
            lambda: M.topology_findings(nearby), "topology endpoint work")
        M.MAX_ENDPOINT_WORK = real_endpoint

        M.MAX_TOPOLOGY_FINDINGS = 1
        crossing_dense = [
            {"name": "H", "width": 1,
             "pts": [(-10.0, 0.0), (10.0, 0.0)]},
            {"name": "V", "width": 1,
             "pts": [(0.0, -10.0), (0.0, 10.0)]},
            {"name": "D", "width": 1,
             "pts": [(-10.0, -10.0), (10.0, 10.0)]},
        ]
        _expect_error(
            lambda: M.topology_findings(crossing_dense),
            "topology findings")

        endpoint_dense = [
            {"name": "Near A", "width": 1,
             "pts": [(0.0, 0.0), (20.0, 0.0)]},
            {"name": "Near B", "width": 1,
             "pts": [(0.0, 3.0), (20.0, 3.0)]},
        ]
        _expect_error(
            lambda: M.topology_findings(endpoint_dense),
            "topology findings")
    finally:
        M.MAX_BUCKET_REFERENCES = real_bucket
        M.MAX_TOPOLOGY_PAIR_WORK = real_pair
        M.MAX_TOPOLOGY_PAIR_SCAN = real_scan
        M.MAX_ENDPOINT_WORK = real_endpoint
        M.MAX_TOPOLOGY_FINDINGS = real_findings


def test_cli_malformed_exit_code(tmp_path=None):
    root = _root(tmp_path)
    xml = root / "s.xml"
    surfaces = root / "u.json"
    out = root / "o.json"
    xml.write_bytes(b'<streets version="2"></streets>\n')
    _unknown_surfaces(surfaces)
    rc = M.main(["--streets", str(xml), "--surfaces", str(surfaces), "--out", str(out)])
    assert rc == 2
    assert not out.exists()


def test_candidate_pixel_limit(tmp_path=None):
    root = _root(tmp_path)
    xml, surfaces = _scene_paths(root)
    assert M.MAX_CANDIDATE_PIXELS == 2000000
    _expect_error(
        lambda: M.audit(
            xml, surfaces,
            max_candidate_pixels=M.MAX_CANDIDATE_PIXELS + 1),
        "max_candidate_pixels 必須介於 0..2000000")
    limited = M.audit(xml, surfaces, max_candidate_pixels=1)
    analysis = limited["candidateAnalysis"]
    assert analysis["status"] == "ok"
    assert analysis["pixelCount"] > 1
    assert analysis["limit"] == 1
    assert analysis["limitScope"] == "perComponentAndGlobalRetainedPixels"
    assert analysis["storageLimitedComponentCount"] > 0
    assert limited["candidates"]
    assert all(item["analysisStatus"] == "aggregate"
               and not item["accepted"] for item in limited["candidates"])
    assert limited["streetSamples"]
    assert "findings" in limited["topology"]
    full = M.audit(xml, surfaces)
    assert full["candidateAnalysis"]["status"] == "ok"
    assert any(c["accepted"] for c in full["candidates"])
    empty_xml = root / "empty-st.xml"
    empty_surf = root / "empty-sf.json"
    _write_streets(empty_xml, [("A", 6, [(0.0, 0.0), (10.0, 0.0)])])
    _unknown_surfaces(empty_surf)
    genuine0 = M.audit(empty_xml, empty_surf)
    assert genuine0["candidateAnalysis"]["status"] == "ok"
    assert genuine0["candidateAnalysis"]["pixelCount"] == 0
    assert genuine0["candidates"] == []
    out = root / "limited.json"
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        rc = M.main(["--streets", str(xml), "--surfaces", str(surfaces),
                     "--out", str(out), "--max-candidate-pixels", "1"])
    assert rc == 0
    warn = err.getvalue()
    assert "used aggregate evidence" in warn
    assert "skipped" not in warn
    dumped = json.loads(out.read_text(encoding="utf-8"))
    assert dumped["candidateAnalysis"]["status"] == "ok"
    assert dumped["candidateAnalysis"]["storageLimitedComponentCount"] > 0
    assert dumped["candidates"]


if __name__ == "__main__":
    _names = sorted(name for name in globals()
                    if name.startswith("test_") and callable(globals()[name]))
    for _name in _names:
        globals()[_name]()
    print("test_audit_streets: OK")
