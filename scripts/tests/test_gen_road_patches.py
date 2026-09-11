#!/usr/bin/env python3
"""Focused contract tests for scripts/gen_road_patches.py."""
from __future__ import annotations

import copy
import hashlib
import importlib.util
import json
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "scripts/gen_road_patches.py"
SPEC = importlib.util.spec_from_file_location("gen_road_patches", MODULE_PATH)
assert SPEC and SPEC.loader
GEN = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GEN)

COUNTS_ZERO = {
    "paved": 0,
    "gravel": 0,
    "dirt-candidate": 0,
    "natural": 0,
    "unknown": 0,
    "dirt-edge": 0,
}


def counts(**values):
    result = dict(COUNTS_ZERO)
    result.update(values)
    return result


def sample(street, segment, x0, y0, x1, y1, width, center, railroad=False):
    return {
        "id": f"sample:{street}:{segment}",
        "streetIndex": street,
        "segIndex": segment,
        "x0": x0,
        "y0": y0,
        "x1": x1,
        "y1": y1,
        "xmlWidth": width,
        "length": ((x1 - x0) ** 2 + (y1 - y0) ** 2) ** 0.5,
        "railroad": railroad,
        "surface": {"centerCounts": center},
    }


def candidate():
    item = {
        "id": "pending",
        "evidenceVersion": 2,
        "accepted": True,
        "analysisStatus": "detailed",
        "area": 30,
        "bbox": {"x0": 10, "y0": 10, "x1": 30, "y1": 12},
        "boundaryTruncated": False,
        "confidence": "high",
        "connection": {
            "d0": 3.0,
            "d1": 4.0,
            "endsWithin8": 2,
            "nearestSegment0Id": "segment:0",
            "nearestSegment1Id": "segment:1",
            "sameSegment": False,
        },
        "coverage": 1.0,
        "dominantSurface": "dirt-candidate",
        "length": 20.0,
        "maxGraphDistance": 4.0,
        "parallelToGraphRatio": 0.25,
        "polyline": [[10.0, 11.0], [20.0, 11.0], [30.0, 11.0]],
        "polylineQ2": [[20, 22], [40, 22], [60, 22]],
        "rejectionReasons": [],
        "surfaceCounts": counts(**{"dirt-candidate": 30}),
        "surfacePurity": 1.0,
        "widthMedian": 3.0,
        "widthP10": 3.0,
        "widthP90": 3.0,
    }
    item["evidenceHash"] = "0" * 64
    evidence_hash = GEN.candidate_evidence_hash(item, "2" * 64, "1" * 64)
    item["evidenceHash"] = evidence_hash
    item["id"] = "c:" + evidence_hash
    return item


def audit_fixture():
    street_samples = [
        sample(0, 0, 0, 0, 10, 0, 6, counts(paved=10)),
        sample(0, 1, 10, 0, 20, 0, 6, counts(paved=7, gravel=3)),
        sample(1, 0, 0, 50, 20, 50, 5, counts(paved=20), railroad=True),
        sample(2, 0, 0, 100, 20, 100, 4, counts(**{"dirt-candidate": 9, "unknown": 1})),
    ]
    return {
        "schemaVersion": 1,
        "source": {
            "xmlSha256": "1" * 64,
            "surfaceFingerprint": "2" * 64,
            "surfaceSource": {
                "pzBuild": "42.test",
                "inputs": [{"layer": "Muldraugh, KY", "priority": 0, "cells": []}],
                "scope": {"mode": "full"},
            },
        },
        "baseline": {
            "streetCount": 3,
            "pointCount": 7,
            "railroadCount": 1,
        },
        "streetSamples": street_samples,
        "candidateAnalysis": {"status": "ok", "acceptedCount": 1},
        "candidates": [candidate()],
    }


def approval_fixture(audit_bytes, audit, *, approve=False, decide=True):
    item = audit["candidates"][0]
    evidence_hash = item["evidenceHash"]
    approved = []
    rejected = []
    if decide and approve:
        approved.append({
            "id": item["id"],
            "evidenceHash": evidence_hash,
            "operation": "add",
            "surface": "dirt",
            "width": 3,
            "searchable": False,
            "reason": "人工確認為公共泥土道路",
        })
    elif decide:
        rejected.append({
            "id": item["id"],
            "evidenceHash": evidence_hash,
            "reason": "人工確認為私有 driveway",
        })
    return {
        "schemaVersion": 1,
        "targetSrc": "Muldraugh, KY",
        "mapId": "Muldraugh, KY",
        "sourceBuild": "42.test",
        "auditSha256": hashlib.sha256(audit_bytes).hexdigest(),
        "auditXmlSha256": "1" * 64,
        "auditSurfaceFingerprint": "2" * 64,
        "approvedCandidates": approved,
        "rejectedCandidates": rejected,
        "remove": [],
        "width": [],
        "surface": [],
        "manualRoads": [],
    }


def write_fixture(tmp_path, *, approve=False, decide=True):
    audit = audit_fixture()
    audit_bytes = (json.dumps(audit, ensure_ascii=False, sort_keys=True) + "\n").encode()
    approval = approval_fixture(audit_bytes, audit, approve=approve, decide=decide)
    audit_path = tmp_path / "audit.json"
    approval_path = tmp_path / "approval.json"
    out_path = tmp_path / "RoadPatches.lua"
    audit_path.write_bytes(audit_bytes)
    approval_path.write_text(json.dumps(approval, ensure_ascii=False), encoding="utf-8")
    return audit, approval, audit_path, approval_path, out_path


def test_deterministic_atomic_generation_and_surface_bake(tmp_path, monkeypatch):
    _, _, audit_path, approval_path, out_path = write_fixture(tmp_path)
    real_replace = GEN.os.replace
    replacements = []

    def observed_replace(source, target):
        replacements.append((Path(source), Path(target)))
        real_replace(source, target)

    monkeypatch.setattr(GEN.os, "replace", observed_replace)
    payload1 = GEN.generate(audit_path, approval_path, out_path)
    first = out_path.read_bytes()
    payload2 = GEN.generate(audit_path, approval_path, out_path)
    second = out_path.read_bytes()

    assert first == second
    assert payload1 == payload2
    assert len(replacements) == 2
    assert all(source.suffix == ".tmp" and target == out_path for source, target in replacements)
    assert not list(tmp_path.glob("*.tmp"))
    assert payload1["targetSrc"] == "Muldraugh, KY"
    assert len(payload1["geometrySet"]) == 2  # railroad excluded
    assert all("|w:" in member and len(compact) == 64
               for member, compact in payload1["geometrySet"].items())
    assert sorted(item["value"] for item in payload1["surface"]) == ["dirt", "paved", "unknown"]
    assert payload1["rejectedCandidateCount"] == 1
    assert payload1["add"] == payload1["bridge"] == []
    text = first.decode("utf-8")
    assert 'sourceBuild = "42.test"' in text
    assert 'xmlSha256 = "' + "1" * 64 + '"' in text


def test_approved_candidate_requires_pinned_detailed_evidence(tmp_path):
    _, approval, audit_path, approval_path, out_path = write_fixture(tmp_path, approve=True)
    payload = GEN.generate(audit_path, approval_path, out_path)
    assert len(payload["add"]) == 1
    operation = payload["add"][0]
    assert operation["surface"] == "dirt"
    assert operation["width"] == 3
    assert operation["searchable"] is False

    approval["approvedCandidates"][0]["evidenceHash"] = "0" * 64
    approval_path.write_text(json.dumps(approval), encoding="utf-8")
    with pytest.raises(GEN.GenerationError, match="evidence hash mismatch"):
        GEN.generate(audit_path, approval_path, out_path)

def test_approved_candidate_cannot_enter_street_search(tmp_path):
    _, approval, audit_path, approval_path, out_path = write_fixture(tmp_path, approve=True)
    approval["approvedCandidates"][0]["searchable"] = True
    approval_path.write_text(json.dumps(approval), encoding="utf-8")
    with pytest.raises(GEN.GenerationError, match="searchable must be false"):
        GEN.generate(audit_path, approval_path, out_path)


@pytest.mark.parametrize("width", [2, 14, 64, 1, 65])
def test_manual_road_width_respects_street_bounds(tmp_path, width):
    _, approval, audit_path, approval_path, out_path = write_fixture(tmp_path)
    approval["manualRoads"] = [{
        "id": "m:verified-junction",
        "operation": "add",
        "points": [10, 0, 10, 20],
        "width": width,
        "surface": "paved",
        "searchable": False,
        "reason": "官方路面確認的路口接線",
    }]
    approval_path.write_text(json.dumps(approval), encoding="utf-8")
    if width in (2, 14, 64):
        payload = GEN.generate(audit_path, approval_path, out_path)
        assert payload["add"][0]["width"] == width
    else:
        out_path.write_bytes(b"previous verified output")
        with pytest.raises(GEN.GenerationError):
            GEN.generate(audit_path, approval_path, out_path)
        assert out_path.read_bytes() == b"previous verified output"


def test_automatic_candidate_keeps_narrow_audit_bounds(tmp_path):
    _, approval, audit_path, approval_path, out_path = write_fixture(tmp_path, approve=True)
    approval["approvedCandidates"][0]["width"] = 14
    approval_path.write_text(json.dumps(approval), encoding="utf-8")
    with pytest.raises(GEN.GenerationError):
        GEN.generate(audit_path, approval_path, out_path)

@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("accepted", False),
        ("analysisStatus", "aggregate"),
        ("boundaryTruncated", True),
        ("rejectionReasons", ["tampered"]),
        ("maxGraphDistance", 999.0),
    ],
)
def test_candidate_payload_tamper_fails_even_when_audit_file_hash_is_re_pinned(
    tmp_path, field, value
):
    audit, _, audit_path, approval_path, out_path = write_fixture(tmp_path)
    audit["candidates"][0][field] = value
    audit_bytes = (json.dumps(audit, ensure_ascii=False, sort_keys=True) + "\n").encode()
    audit_path.write_bytes(audit_bytes)
    approval = approval_fixture(audit_bytes, audit)
    approval_path.write_text(json.dumps(approval, ensure_ascii=False), encoding="utf-8")
    with pytest.raises(GEN.GenerationError, match="evidence payload hash mismatch"):
        GEN.generate(audit_path, approval_path, out_path)


def test_unresolved_provisional_candidate_and_aliases_fail_closed(tmp_path):
    _, _, audit_path, approval_path, out_path = write_fixture(tmp_path, decide=False)
    with pytest.raises(GEN.GenerationError, match="lack a decision"):
        GEN.generate(audit_path, approval_path, out_path)
    with pytest.raises(GEN.GenerationError, match="path alias rejected"):
        GEN.generate(audit_path, audit_path, out_path)


def test_schema_source_hash_and_candidate_status_are_strict(tmp_path):
    audit, approval, audit_path, approval_path, out_path = write_fixture(tmp_path)
    approval["unexpectedAlias"] = []


    approval_path.write_text(json.dumps(approval), encoding="utf-8")
    with pytest.raises(GEN.GenerationError, match="keys mismatch"):
        GEN.generate(audit_path, approval_path, out_path)

    audit["candidateAnalysis"]["status"] = "skipped"
    audit_bytes = (json.dumps(audit, sort_keys=True) + "\n").encode()
    audit_path.write_bytes(audit_bytes)
    approval = approval_fixture(audit_bytes, audit)
    approval_path.write_text(json.dumps(approval), encoding="utf-8")
    with pytest.raises(GEN.GenerationError, match="status must be 'ok'"):
        GEN.generate(audit_path, approval_path, out_path)
def test_lua_string_encoder_escapes_quotes_and_rejects_c0():
    assert GEN._lua_string('a"\\地圖') == '"a\\"\\\\地圖"'
    with pytest.raises(GEN.GenerationError, match="C0 controls"):
        GEN._lua_string("bad\nstring")


def test_surface_dominance_threshold_and_mapping():
    assert GEN.classify_surface(counts(paved=8, gravel=2), "fixture") == "paved"
    assert GEN.classify_surface(counts(gravel=9, paved=1), "fixture") == "gravel"
    assert GEN.classify_surface(counts(**{"dirt-candidate": 8, "unknown": 2}), "fixture") == "dirt"
    assert GEN.classify_surface(counts(paved=7, gravel=3), "fixture") == "unknown"
    assert GEN.classify_surface(counts(natural=10), "fixture") == "unknown"

@pytest.mark.parametrize(
    ("reasons", "message"),
    [([None], "invalid"), (["unknownReason"], "invalid"), (["length", "length"], "duplicate")],
)
def test_rejection_reason_enum_is_strict(reasons, message):
    item = candidate()
    item["accepted"] = False
    item["rejectionReasons"] = reasons
    digest = GEN.candidate_evidence_hash(item, "2" * 64, "1" * 64)
    item["id"], item["evidenceHash"] = "c:" + digest, digest
    with pytest.raises(GEN.GenerationError, match=message):
        GEN._validate_candidate_evidence(item, item["id"], "2" * 64, "1" * 64, False)



def test_candidate_nested_schema_and_ranges_are_strict():
    cases = []
    item = candidate()
    item["bbox"]["extra"] = 1
    cases.append(item)
    item = candidate()
    del item["connection"]["d0"]
    cases.append(item)
    item = candidate()
    item["surfaceCounts"]["extra"] = 1
    cases.append(item)
    item = candidate()
    item["widthP10"], item["widthMedian"], item["widthP90"] = 4.0, 3.0, 2.0
    cases.append(item)
    for item in cases:
        digest = GEN.candidate_evidence_hash(item, "2" * 64, "1" * 64)
        item["id"], item["evidenceHash"] = "c:" + digest, digest
        with pytest.raises(GEN.GenerationError):
            GEN._validate_candidate_evidence(item, item["id"], "2" * 64, "1" * 64, False)


def test_json_boundary_rejects_duplicate_keys_and_nonfinite_numbers(tmp_path):
    path = tmp_path / "bad.json"
    path.write_text('{"a":1,"a":2}', encoding="utf-8")
    with pytest.raises(GEN.GenerationError, match="duplicate JSON key"):
        GEN._load_json(path, "fixture")
    path.write_text('{"x":NaN}', encoding="utf-8")
    with pytest.raises(GEN.GenerationError, match="non-finite JSON"):
        GEN._load_json(path, "fixture")


def test_segment_identity_uses_source_full_geometry_and_index_not_name():
    geometry = GEN.geometry_key([0, 0, 10, 0, 20, 0])
    compact = GEN.compact_geometry_key("Muldraugh, KY", geometry)
    first = GEN.segment_id(compact, 0)

    second = GEN.segment_id(compact, 1)
    assert first != second and len(first) < 80
    assert "Muldraugh, KY" not in first and geometry not in first
    assert GEN.fingerprint_key([0, 0, 10, 0, 20, 0], 6).endswith("|w:12")
    non_ascii = GEN.compact_geometry_key("地圖", geometry)
    assert len(non_ascii) == 64 and GEN.segment_id(non_ascii, 0).endswith(":0")
def test_report_list_caps_fail_before_grouping():
    audit = audit_fixture()
    audit["streetSamples"] = [audit["streetSamples"][0]] * (GEN.MAX_TOTAL_SEGMENTS + 1)
    audit["baseline"]["pointCount"] = (
        audit["baseline"]["streetCount"] + len(audit["streetSamples"])
    )
    with pytest.raises(GEN.GenerationError, match="streetSamples exceeds"):
        GEN._reconstruct_streets(audit, "Muldraugh, KY")

    audit = audit_fixture()
    audit["candidates"] = [audit["candidates"][0]] * (GEN.MAX_CANDIDATES + 1)
    with pytest.raises(GEN.GenerationError, match="candidates exceeds"):
        GEN._candidate_operations(audit, [], [], "Muldraugh, KY", "2" * 64, "1" * 64)


def test_geometry_limits_reject_resource_abuse_before_string_bake():
    assert GEN.geometry_key([-32768.0, 0.0, -32767.0, 0.0])
    assert GEN.geometry_key([32766.5, 0.0, 32767.5, 0.0])
    with pytest.raises(GEN.GenerationError, match="world coordinate domain"):
        GEN.geometry_key([-32768.5, 0.0, -32767.0, 0.0])
    with pytest.raises(GEN.GenerationError, match="world coordinate domain"):
        GEN.geometry_key([32766.0, 0.0, 32768.0, 0.0])
    with pytest.raises(GEN.GenerationError, match="4096 points"):
        GEN.geometry_key([0.0, 0.0] * 10000)
    with pytest.raises(GEN.GenerationError, match="16384"):
        GEN.geometry_key([0.0, 0.0, 20000.0, 0.0])
    with pytest.raises(GEN.GenerationError, match="1..64"):
        GEN._road_width(65, "width")

def test_input_byte_string_and_candidate_point_caps(tmp_path):
    path = tmp_path / "oversized.json"
    path.write_text("{}", encoding="utf-8")
    with pytest.raises(GEN.GenerationError, match="exceeds 1 bytes"):
        GEN._load_json(path, "fixture", 1)
    with path.open("wb") as handle:
        handle.truncate(GEN.MAX_APPROVAL_BYTES + 1)
    with pytest.raises(GEN.GenerationError, match="exceeds"):
        GEN._load_json(path, "approval", GEN.MAX_APPROVAL_BYTES)
    with pytest.raises(GEN.GenerationError, match="1024 characters"):
        GEN._bounded_string("x" * 1025, "targetSrc", 1024)
    item = candidate()
    item["polyline"] = [[0.0, 0.0]] * 8192
    item["polylineQ2"] = [[0, 0]] * 8192
    assert len(GEN.candidate_evidence_hash(item, "2" * 64, "1" * 64)) == 64
    item["polyline"].append([0.0, 0.0])
    item["polylineQ2"].append([0, 0])
    with pytest.raises(GEN.GenerationError, match="8192 points"):
        GEN.candidate_evidence_hash(item, "2" * 64, "1" * 64)
