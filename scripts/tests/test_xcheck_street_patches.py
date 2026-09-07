"""道路交叉檢查的資料安全回歸；直接執行 main 與真實解析／幾何程式，不依賴 pytest。"""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
from pathlib import Path
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import xcheck_street_patches as X


CALL = 'map_nav:add_xml_patch("Vanilla", nil, {60,60}, {61,59})'
POINTS = [(30, 30), (60, 30), (60, 60), (90, 60), (120, 60)]


def store(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False) + "\n", encoding="utf-8")


def fixture(root):
    paths = {name: root / filename for name, filename in (
        ("patch-lua", "patch.lua"), ("streets", "streets.xml"),
        ("worldmap", "worldmap.xml"), ("surfaces", "surfaces.json"),
        ("audit", "audit.json"), ("approvals", "approvals.json"),
        ("out", "report.json"), ("emit-approvals", "merged.json"),
    )}
    paths["patch-lua"].write_text("-- Test Road\n" + CALL + "\n", encoding="utf-8")
    pts = "".join(f'<point x="{x}" y="{y}"/>' for x, y in POINTS)
    paths["streets"].write_text(
        f'<streets version="1"><street name="Test Road" width="4"><points>{pts}</points></street></streets>',
        encoding="utf-8")
    paths["worldmap"].write_text(
        '<world><cell x="0" y="0"><feature><properties><property name="highway" value="primary"/>'
        '</properties><geometry type="Polygon"><coordinates><point x="61" y="0"/>'
        '<point x="150" y="0"/><point x="150" y="59"/><point x="61" y="59"/>'
        '</coordinates></geometry></feature></cell></world>', encoding="utf-8")
    store(paths["surfaces"], {
        "schemaVersion": 1, "mapId": "Muldraugh, KY", "cellSize": X.A.CELL_SIZE,
        "classes": list(X.A.CLASSES),
        "source": {"pzBuild": "42.test", "scope": {
            "mode": "full", "requestedRegion": None, "selectedCellCount": 1, "bounds": [0, 0, 0, 0]},
            "inputs": [{"priority": 0, "layer": "Muldraugh, KY",
                        "cells": [[0, 0, "0_0.lotheader", "world_0_0.lotpack"]]}]},
        "cells": [{"x": 0, "y": 0, "runs": [[0, X.A.CELL_SIZE ** 2, X.A.CLASSES.index("natural")]]}],
    })
    store(paths["audit"], {"candidates": []})
    store(paths["approvals"], {
        "schemaVersion": 1, "targetSrc": "Muldraugh, KY", "mapId": "Muldraugh, KY", "sourceBuild": "42.test",
        "auditSha256": hashlib.sha256(paths["audit"].read_bytes()).hexdigest(),
        "auditXmlSha256": hashlib.sha256(paths["streets"].read_bytes()).hexdigest(),
        "auditSurfaceFingerprint": hashlib.sha256(paths["surfaces"].read_bytes()).hexdigest(),
        "approvedCandidates": [], "rejectedCandidates": [], "remove": [], "manualRoads": [],
    })
    return paths


def run(paths):
    args = [arg for name, path in paths.items() for arg in ("--" + name, str(path))]
    with contextlib.redirect_stdout(io.StringIO()):
        assert X.main(args) == 0
    return json.loads(paths["out"].read_text(encoding="utf-8"))


def rejected(fn):
    try:
        fn()
    except X.XcheckError:
        return
    raise AssertionError("unsafe input was accepted")


def merged(paths):
    return json.loads(paths["emit-approvals"].read_text(encoding="utf-8"))


def evidence(paths):
    return X.Evidence(X.load_highway_polygons(paths["worldmap"]),
                      X.A.SurfaceIndex(X.A.load_surfaces(paths["surfaces"].read_bytes())))


def keep_official_segment(paths):
    approvals = json.loads(paths["approvals"].read_text(encoding="utf-8"))
    compact = X.G.compact_geometry_key("Muldraugh, KY", X.G.geometry_key([v for point in POINTS for v in point]))
    approvals["remove"] = [X.G.segment_id(compact, i) for i in (0, 3)]
    store(paths["approvals"], approvals)
    report = run(paths)
    assert report["counts"]["generatedManualRoads"] == 0
    assert report["counts"]["manualFollowUp"] == 1
    assert merged(paths)["remove"] == approvals["remove"], "combined removals erased the whole street"


def reject_wrong_pin(paths, source):
    paths[source].write_bytes(paths[source].read_bytes() + b" ")
    rejected(lambda: run(paths))
    assert not paths["out"].exists() and not paths["emit-approvals"].exists()


def protect_alias(paths, output, input_name):
    original = paths[input_name].read_bytes() if paths[input_name].exists() else None
    aliased = {**paths, output: paths[input_name]}
    rejected(lambda: run(aliased))
    if original is not None:
        assert paths[input_name].read_bytes() == original, "input was overwritten"


def protect_hardlink(paths):
    paths["out"].hardlink_to(paths["approvals"])
    protect_alias(paths, "out", "out")


def official_coordinates(paths):
    ev = evidence(paths)
    # 官方點距角落 sqrt(0.6^2+0.6^2)<1；線索偏差每軸0.4，卻在容差外。
    streets = [{"name": "Edge Road", "pts": [(30, 30), (60.4, 59.6), (90, 60)], "width": 4}]
    active = [{"raw": [(60.0, 60.0)], "new": [(61, 59)], "street": "Edge Road"}]
    X.classify(active, streets, ev)
    assert active[0]["klass"] == "cosmetic", "approximate clue became evidence against official geometry"
    assert active[0]["rawEvidence"][0]["x"] == 60.4


def missing_surface(paths):
    ev = X.Evidence({}, X.A.SurfaceIndex({"cellSize": X.A.CELL_SIZE, "cells": {}}))
    rejected(lambda: ev.probe(30, 30))


def comments(paths):
    text = "\n".join([
        "-- Test Road", CALL, "--[[", CALL, "]]", "--[==[", CALL, "]==]",
        "local enabled = false -- " + CALL, "-- " + CALL,
        "local example = '" + CALL + "'", "local example2 = [=[" + CALL + "]=]",
        'local label = "-- not a comment"; ' + CALL,
    ])
    active, disabled = X.parse_derpy_patches(text)
    assert [entry["line"] for entry in active] == [2, 13], "comment/string content became active patches"
    assert [entry["line"] for entry in disabled] == [4, 7, 9, 10]
    rejected(lambda: X.parse_derpy_patches("--[[\n" + CALL))


def identifier_boundary(paths):
    paths["patch-lua"].write_text(CALL.replace("add_xml_patch", "ignore_add_xml_patch"), encoding="utf-8")
    result = run(paths)
    assert result["counts"]["activePatches"] == 0 and result["counts"]["generatedManualRoads"] == 0


def unsupported_call(paths):
    paths["patch-lua"].write_text(CALL.replace("add_xml_patch(", "add_xml_patch -- note\n("), encoding="utf-8")
    rejected(lambda: run(paths))
    assert not paths["out"].exists()


def in_place_idempotence(paths):
    first = run(paths)
    assert first["counts"]["generatedManualRoads"] == 1 and first["counts"]["generatedRemoves"] == 2
    initial = merged(paths)
    paths["approvals"] = paths["emit-approvals"]
    second = run(paths)
    assert second["counts"]["alreadyApproved"] == 1 and second["counts"]["generatedManualRoads"] == 0
    assert merged(paths) == initial, "rerun changed an existing approval"


def conflict(paths, partial_remove):
    run(paths)
    approvals = merged(paths)
    if partial_remove:
        approvals["remove"] = approvals["remove"][:1]
    else:
        approvals["manualRoads"][0]["points"][0] += 0.5
    store(paths["approvals"], approvals)
    result = run(paths)
    assert result["counts"]["alreadyApproved"] == 0, "different or partial effect called already approved"
    assert result["counts"]["generatedManualRoads"] == 0 and result["counts"]["manualFollowUp"] == 1
    assert merged(paths) == approvals, "conflict rewrote manual data"


def edge_tolerance(paths):
    ev = evidence(paths)
    assert ev.probe(70, 60)["onRoad"], "exact 1-square edge is inside the declared tolerance"
    assert ev.probe(70, 59.9996)["onRoad"], "rounding excluded a point inside tolerance"
    assert not ev.probe(70, 60.0004)["onRoad"], "rounding included a point outside tolerance"


def main():
    cases = [
        ("keep-official", keep_official_segment),
        ("audit-pin", lambda p: reject_wrong_pin(p, "audit")),
        ("surface-pin", lambda p: reject_wrong_pin(p, "surfaces")),
        ("report-input-alias", lambda p: protect_alias(p, "out", "approvals")),
        ("report-emit-alias", lambda p: protect_alias(p, "out", "emit-approvals")),
        ("emit-evidence-alias", lambda p: protect_alias(p, "emit-approvals", "streets")),
        ("hardlink-alias", protect_hardlink),
        ("official-coordinates", official_coordinates),
        ("missing-surface", missing_surface),
        ("comments", comments),
        ("identifier-boundary", identifier_boundary),
        ("unsupported-call", unsupported_call),
        ("in-place-idempotence", in_place_idempotence),
        ("id-conflict", lambda p: conflict(p, False)),
        ("partial-remove", lambda p: conflict(p, True)),
        ("edge-tolerance", edge_tolerance),
    ]
    failed = []
    with tempfile.TemporaryDirectory(prefix="street-xcheck-test-") as tmp:
        for name, check in cases:
            root = Path(tmp) / name
            root.mkdir()
            try:
                check(fixture(root))
            except Exception as exc:
                failed.append(name)
                print(f"FAIL {name}: {type(exc).__name__}: {exc}")
    if failed:
        print(f"test_xcheck_street_patches: {len(failed)} failed")
        return 1
    print(f"checked {len(cases)} safety cases")
    print("test_xcheck_street_patches: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
