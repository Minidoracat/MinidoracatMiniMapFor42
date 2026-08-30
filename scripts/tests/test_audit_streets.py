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
    while i < SQUARES:
        j = i + 1
        v = flat[i]
        while j < SQUARES and flat[j] == v:
            j += 1
        runs.append([i, j - i, v])
        i = j
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
    # Test St 沿 x=10、y=10..80；corridor 在 x=16..19、y=20..60（距路中心 7.5≤8）
    _write_streets(xml, [
        ("Test St", 6, [(10.0, 10.0), (10.0, 80.0)]),
        ("Side St", 6, [(10.0, 80.0), (120.0, 80.0)]),
    ])
    _write_surfaces(surfaces, [
        (16, 20, 19, 60, "dirt-candidate"),       # 狹長 corridor
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
    bb = corridor["bbox"]
    assert bb["x0"] <= 19 and bb["x1"] >= 16
    assert bb["y0"] <= 20 and bb["y1"] >= 60

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

    target = root / "atomic.json"
    target.write_bytes(b"original")
    real_replace = M.os.replace

    def fail_replace(source, destination):
        raise OSError("replace fixture")

    M.os.replace = fail_replace
    try:
        try:
            M.write_canonical_file({"new": True}, target)
        except OSError as exc:
            assert "replace fixture" in str(exc)
        else:
            raise AssertionError("atomic replace failure must propagate")
    finally:
        M.os.replace = real_replace
    assert target.read_bytes() == b"original"
    assert not list(root.glob(".atomic.json.*.tmp"))


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


def test_no_binary_map_decoder():
    src = SCRIPT.read_text(encoding="utf-8")
    assert "struct.unpack" not in src
    assert "import struct" not in src


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
    limited = M.audit(xml, surfaces, max_candidate_pixels=1)
    assert limited["candidateAnalysis"]["status"] == "skipped"
    assert limited["candidateAnalysis"]["reason"] == "candidatePixelLimit"
    assert limited["candidateAnalysis"]["pixelCount"] > 1
    assert limited["candidateAnalysis"]["limit"] == 1
    assert limited["candidates"] == []
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
    assert "candidate analysis skipped" in warn
    assert "region surface JSON" in warn
    dumped = json.loads(out.read_text(encoding="utf-8"))
    assert dumped["candidateAnalysis"]["status"] == "skipped"
    assert dumped["candidates"] == []


if __name__ == "__main__":
    test_malformed_schema_version()
    test_malformed_class_table()
    test_malformed_rle_gap_overlap_range()
    test_surface_source_mismatches()
    test_malformed_xml()
    test_corridor_vs_field_and_negatives()
    test_byte_identical_and_preview()
    test_full_region_missing_and_boundary()
    test_width_p90_always_rejected()
    test_path_aliases_and_atomic_write()
    test_topology_findings()
    test_no_binary_map_decoder()
    test_cli_malformed_exit_code()
    test_candidate_pixel_limit()
    print("test_audit_streets: OK")
