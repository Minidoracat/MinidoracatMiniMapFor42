#!/usr/bin/env python3
"""Generate deterministic RoadPatch Lua data from road-audit-v1 evidence.

The runtime never reads XML or computes a cryptographic hash. This generator
pins the complete audit, reconstructs every official street geometry from its
segment evidence, and emits an exact target-container fingerprint plus patch
operations. Every provisionally accepted candidate must be explicitly approved
or rejected; omission is an error.

Usage:
    python scripts/gen_road_patches.py [--audit PATH] [--approvals PATH] [--out PATH]
        [--legacy-audit PATH ...] [--streets PATH]

``--legacy-audit`` takes the audit of a previous official streets.xml pinned in
``approvals.legacyAudits``. Streets TIS redrew since then are emitted as ``legacy``
aliases so translation carriers still bundling that build can certify.

``--streets`` takes the official streets.xml the audit was built from (its SHA-256
must equal ``audit.source.xmlSha256``). It is required only when a manual road
carries ``name``: the name must be an official street name verbatim, and every
official street with that name must be fully removed (the manual road takes over
its street search; partial replacements keep an official segment searchable).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any, NoReturn

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_AUDIT = REPO_ROOT / "target/road-audit-v2.json"
DEFAULT_APPROVALS = REPO_ROOT / "scripts/road_patch_approvals.json"
DEFAULT_OUT = (
    REPO_ROOT
    / "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42"
    / "42/media/lua/shared/MinidoracatMiniMapRoadPatches.lua"
)
SHA256_HEX_LEN = 64
SURFACES = frozenset({"paved", "gravel", "dirt", "unknown"})
AUDIT_SURFACES = (
    "paved", "gravel", "dirt-candidate", "natural", "unknown", "dirt-edge")
AUDIT_REJECTION_REASONS = frozenset({
    "length", "medianWidth", "widthP90", "widthSpread", "coverage",
    "surfaceImpure", "unconnected", "unverifiedTerminus", "sameAttachment",
    "noLongAxis", "field", "courtyard", "parallelResidual",
    "boundaryTruncated", "storageLimit",
})
MAX_POINTS_PER_STREET = 4096
MAX_SEGMENT_LENGTH = 16384
MAX_STREETS = 65536
MAX_WIDTH = 64
MAX_TOTAL_SEGMENTS = 16384
MAX_CANDIDATES = 10000
MAX_CANDIDATE_POLYLINE_POINTS = 8192
MAX_AUDIT_BYTES = 64 * 1024 * 1024
MAX_APPROVAL_BYTES = 1024 * 1024
MAX_IDENTITY_STRING = 1024
MAX_LEGACY_AUDITS = 4
MAX_REASON_STRING = 4096
MIN_WORLD_COORD = -32768
MAX_WORLD_COORD = 32767.5


class GenerationError(ValueError):
    """Input evidence is incomplete, stale, ambiguous, or internally invalid."""


def _fail(message: str) -> NoReturn:
    raise GenerationError(message)


def _object(value: Any, where: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        _fail(f"{where} must be an object")
    return value


def _array(value: Any, where: str) -> list[Any]:
    if not isinstance(value, list):
        _fail(f"{where} must be an array")
    return value


def _integer(value: Any, where: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        _fail(f"{where} must be an integer >= {minimum}")
    return value


def _number(value: Any, where: str, *, positive: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        _fail(f"{where} must be a finite number")
    number = float(value)
    if not math.isfinite(number) or (positive and number <= 0):
        suffix = " > 0" if positive else ""
        _fail(f"{where} must be a finite number{suffix}")
    return number


def _string(value: Any, where: str, *, nonempty: bool = True) -> str:
    if not isinstance(value, str) or (nonempty and not value):
        _fail(f"{where} must be a {'non-empty ' if nonempty else ''}string")
    return value


def _bounded_string(value: Any, where: str, maximum: int) -> str:
    text = _string(value, where)
    if len(text) > maximum:
        _fail(f"{where} exceeds {maximum} characters")
    return text

def _sha(value: Any, where: str) -> str:
    text = _string(value, where)
    if len(text) != SHA256_HEX_LEN or any(c not in "0123456789abcdef" for c in text):
        _fail(f"{where} must be a lowercase SHA-256 hex digest")
    return text


def _exact_keys(value: dict[str, Any], expected: set[str], where: str) -> None:
    actual = set(value)
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        _fail(f"{where} keys mismatch (missing={missing}, extra={extra})")


def canonical_sha256(value: Any) -> str:
    payload = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False
    ).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def quantize(value: Any, where: str) -> int:
    return math.floor(_number(value, where) * 2 + 0.5)


def _road_width(value: Any, where: str) -> float:
    width = _number(value, where, positive=True)
    if width > MAX_WIDTH:
        _fail(f"{where} must be within 1..{MAX_WIDTH}")
    return width


def _validate_points(points: list[float], where: str = "geometry") -> None:
    if len(points) < 4 or len(points) % 2:
        _fail(f"{where} must contain at least two x/y points")
    if len(points) // 2 > MAX_POINTS_PER_STREET:
        _fail(f"{where} exceeds {MAX_POINTS_PER_STREET} points")
    for index, value in enumerate(points):
        number = _number(value, f"{where}[{index}]")
        if number < MIN_WORLD_COORD or number > MAX_WORLD_COORD:
            _fail(f"{where}[{index}] outside world coordinate domain")
    limit2 = MAX_SEGMENT_LENGTH * MAX_SEGMENT_LENGTH
    for index in range(0, len(points) - 2, 2):
        dx = points[index + 2] - points[index]
        dy = points[index + 3] - points[index + 1]
        if dx * dx + dy * dy > limit2:
            _fail(f"{where} segment exceeds {MAX_SEGMENT_LENGTH}")


OPERATION_SIMPLIFY_EPSILON = 0.25  # 同 runtime CUT_MERGE 量級；q2 精度 0.005 之上


def _simplify_polyline(points: list[float], epsilon: float) -> list[float]:
    """Douglas-Peucker 簡化 add/bridge operation 幾何。

    稽核 polylineQ2 是 row-span 骨架的逐格點（169 格＝169 點），直接入 patch
    會讓 runtime 建圖對每格微段做交叉切割（per-segment cut 上限爆掉）。
    證據驗證（evidenceHash）仍用原始點；僅 operation 輸出簡化，幾何保形。
    """
    n = len(points) // 2
    if n <= 2:
        return list(points)
    keep = [False] * n
    keep[0] = keep[n - 1] = True
    stack = [(0, n - 1)]
    while stack:
        i0, i1 = stack.pop()
        if i1 - i0 < 2:
            continue
        ax, ay = points[2 * i0], points[2 * i0 + 1]
        dx = points[2 * i1] - ax
        dy = points[2 * i1 + 1] - ay
        norm = math.hypot(dx, dy)
        best, best_d = -1, epsilon
        for i in range(i0 + 1, i1):
            px, py = points[2 * i] - ax, points[2 * i + 1] - ay
            d = math.hypot(px, py) if norm == 0.0 else abs(px * dy - py * dx) / norm
            if d > best_d:
                best, best_d = i, d
        if best >= 0:
            keep[best] = True
            stack.append((i0, best))
            stack.append((best, i1))
    out: list[float] = []
    for i in range(n):
        if keep[i]:
            out.extend((points[2 * i], points[2 * i + 1]))
    return out


def geometry_key(points: list[float]) -> str:
    """Translation-independent full q2 polyline identity (no width or name)."""
    _validate_points(points)
    values = [str(len(points) // 2)]
    for index, value in enumerate(points):
        values.append(str(quantize(value, f"geometry[{index}]")))
    return ":".join(values)


def fingerprint_key(points: list[float], width: float) -> str:
    """Target-container set member: full q2 geometry plus q2 XML width."""
    return f"{geometry_key(points)}|w:{quantize(width, 'street width')}"


def compact_geometry_key(source: str, geometry: str) -> str:
    return hashlib.sha256((source + "\0" + geometry).encode("utf-8")).hexdigest()


def segment_id(compact_key: str, segment_index: int) -> str:
    return f"{compact_key}:{segment_index}"


def classify_surface(counts_value: Any, where: str) -> str:
    counts = _object(counts_value, where)
    values = {key: _integer(counts.get(key), f"{where}.{key}") for key in AUDIT_SURFACES}
    total = sum(values.values())
    if total == 0:
        return "unknown"
    dominant = max(AUDIT_SURFACES, key=lambda key: values[key])
    dominant_count = values[dominant]
    if sum(1 for count in values.values() if count == dominant_count) != 1:
        return "unknown"
    if dominant_count / total < 0.8:
        return "unknown"
    return {
        "paved": "paved",
        "gravel": "gravel",
        "dirt-candidate": "dirt",
    }.get(dominant, "unknown")


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            _fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_constant(value: str) -> NoReturn:
    _fail(f"non-finite JSON number rejected: {value}")


def _load_json(path: Path, label: str, maximum_bytes: int | None = None) -> tuple[dict[str, Any], bytes]:
    try:
        size = path.stat().st_size
        if maximum_bytes is not None and size > maximum_bytes:
            _fail(f"{label} exceeds {maximum_bytes} bytes")
        raw = path.read_bytes()
    except OSError as exc:
        _fail(f"cannot read {label} {path}: {exc}")
    if maximum_bytes is not None and len(raw) > maximum_bytes:
        _fail(f"{label} exceeds {maximum_bytes} bytes after read")
    try:
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_unique_object,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        _fail(f"invalid UTF-8 JSON in {label} {path}: {exc}")
    return _object(value, label), raw


def _reconstruct_streets(
    audit: dict[str, Any], target_src: str
) -> tuple[list[dict[str, Any]], dict[str, str]]:
    baseline = _object(audit.get("baseline"), "audit.baseline")
    street_count = _integer(baseline.get("streetCount"), "audit.baseline.streetCount", 1)
    if street_count > MAX_STREETS:
        _fail(f"audit streetCount exceeds {MAX_STREETS}")
    point_count = _integer(baseline.get("pointCount"), "audit.baseline.pointCount", 2)
    railroad_count = _integer(baseline.get("railroadCount"), "audit.baseline.railroadCount")
    samples = _array(audit.get("streetSamples"), "audit.streetSamples")
    if len(samples) > MAX_TOTAL_SEGMENTS:
        _fail(f"audit.streetSamples exceeds {MAX_TOTAL_SEGMENTS}")
    if len(samples) != point_count - street_count:
        _fail(
            "audit.streetSamples must contain every point-pair "
            f"({len(samples)} != {point_count} - {street_count})"
        )

    grouped: dict[int, list[dict[str, Any]]] = {}
    sample_ids: set[str] = set()
    for sample_pos, raw_sample in enumerate(samples):
        where = f"audit.streetSamples[{sample_pos}]"
        sample = _object(raw_sample, where)
        sample_id_value = _string(sample.get("id"), f"{where}.id")
        if sample_id_value in sample_ids:
            _fail(f"duplicate street sample id: {sample_id_value}")
        sample_ids.add(sample_id_value)
        street_index = _integer(sample.get("streetIndex"), f"{where}.streetIndex")
        if street_index >= street_count:
            _fail(f"{where}.streetIndex outside baseline streetCount")
        _integer(sample.get("segIndex"), f"{where}.segIndex")
        length = _number(sample.get("length"), f"{where}.length", positive=True)
        if length > MAX_SEGMENT_LENGTH:
            _fail(f"{where}.length exceeds {MAX_SEGMENT_LENGTH}")
        _road_width(sample.get("xmlWidth"), f"{where}.xmlWidth")
        for coord in ("x0", "y0", "x1", "y1"):
            _number(sample.get(coord), f"{where}.{coord}")
        if not isinstance(sample.get("railroad"), bool):
            _fail(f"{where}.railroad must be boolean")
        surface = _object(sample.get("surface"), f"{where}.surface")
        classify_surface(surface.get("centerCounts"), f"{where}.surface.centerCounts")
        grouped.setdefault(street_index, []).append(sample)

    if set(grouped) != set(range(street_count)):
        missing = sorted(set(range(street_count)) - set(grouped))
        _fail(f"streetSamples missing streetIndex values: {missing[:10]}")

    streets: list[dict[str, Any]] = []
    surface_by_segment: dict[str, str] = {}
    seen_fingerprint: set[str] = set()
    seen_compact: set[str] = set()
    railroad_seen = 0
    for street_index in range(street_count):
        segments = sorted(grouped[street_index], key=lambda sample: sample["segIndex"])
        if [sample["segIndex"] for sample in segments] != list(range(len(segments))):
            _fail(f"streetIndex {street_index} segIndex values must be contiguous from zero")
        # The sample loop above already validated railroad/xmlWidth/x0/y0/x1/y1
        # for every sample, so this pass only compares the accepted values.
        railroad = segments[0]["railroad"]
        width = segments[0]["xmlWidth"]
        points = [segments[0]["x0"], segments[0]["y0"]]
        surfaces: list[str] = []
        for seg_index, sample in enumerate(segments):
            if sample["railroad"] is not railroad:
                _fail(f"streetIndex {street_index} mixes railroad flags")
            if sample["xmlWidth"] != width:
                _fail(f"streetIndex {street_index} mixes xmlWidth values")
            if (
                quantize(sample["x0"], "x0") != quantize(points[-2], "previous x1")
                or quantize(sample["y0"], "y0") != quantize(points[-1], "previous y1")
            ):
                _fail(f"streetIndex {street_index} segment geometry is discontinuous at {seg_index}")
            points.extend((sample["x1"], sample["y1"]))
            surfaces.append(
                classify_surface(
                    sample["surface"]["centerCounts"],
                    f"street {street_index} segment {seg_index} centerCounts",
                )
            )
        if railroad:
            railroad_seen += 1
            continue
        geometry = geometry_key(points)
        fingerprint = fingerprint_key(points, width)
        if fingerprint in seen_fingerprint:
            _fail(f"duplicate usable quantized street geometry/width at streetIndex {street_index}")
        seen_fingerprint.add(fingerprint)
        compact = compact_geometry_key(target_src, geometry)
        if compact in seen_compact:
            _fail(f"compact geometry key collision at streetIndex {street_index}")
        seen_compact.add(compact)
        street = {
            "streetIndex": street_index,
            "source": target_src,
            "width": width,
            "points": points,
            "geometry": geometry,
            "fingerprint": fingerprint,
            "compact": compact,
            "surfaces": surfaces,
        }
        streets.append(street)
        for seg_index, surface in enumerate(surfaces):
            identity = segment_id(compact, seg_index)
            if identity in surface_by_segment:
                _fail(f"duplicate segment identity: {identity}")
            surface_by_segment[identity] = surface

    if railroad_seen != railroad_count:
        _fail(f"railroad street count mismatch ({railroad_seen} != {railroad_count})")
    if len(streets) != street_count - railroad_count:
        _fail("usable street count does not match baseline")
    return streets, surface_by_segment


def _legacy_geometry(
    approvals: dict[str, Any],
    legacy_inputs: list[tuple[dict[str, Any], bytes]],
    streets: list[dict[str, Any]],
    street_count: int,
    map_id: str,
    target_src: str,
    current_xml_sha: str,
) -> tuple[list[dict[str, str]], dict[str, dict[str, Any]]]:
    """Map every previous-official geometry TIS redrew to its current street.

    Translation carriers bundle a copy of an older streets.xml. Alignment is by street
    index, so a pinned previous audit must keep the same street count and railroad
    positions; anything else is ambiguous and fails closed.
    """
    pins = _array(approvals.get("legacyAudits", []), "approvals.legacyAudits")
    if len(pins) > MAX_LEGACY_AUDITS:
        _fail(f"approvals.legacyAudits exceeds {MAX_LEGACY_AUDITS}")
    by_digest = {hashlib.sha256(raw).hexdigest(): audit for audit, raw in legacy_inputs}
    if len(by_digest) != len(legacy_inputs):
        _fail("duplicate --legacy-audit input")
    current = {street["fingerprint"] for street in streets}
    by_index = {street["streetIndex"]: street for street in streets}
    sources: list[dict[str, str]] = []
    legacy: dict[str, dict[str, Any]] = {}
    used: set[str] = set()
    for pos, raw_pin in enumerate(pins):
        where = f"approvals.legacyAudits[{pos}]"
        pin = _object(raw_pin, where)
        _exact_keys(pin, {"sourceBuild", "auditSha256", "auditXmlSha256"}, where)
        build = _bounded_string(pin["sourceBuild"], f"{where}.sourceBuild", MAX_IDENTITY_STRING)
        digest = _sha(pin["auditSha256"], f"{where}.auditSha256")
        if digest in used:
            _fail(f"{where} pins the same legacy audit twice")
        audit = by_digest.get(digest)
        if audit is None:
            _fail(f"{where} audit not provided (pass it with --legacy-audit)")
        used.add(digest)
        if audit.get("schemaVersion") != 1:
            _fail(f"{where} audit.schemaVersion must be road-audit-v1 (1)")
        source = _object(audit.get("source"), f"{where} audit.source")
        xml_sha = _sha(source.get("xmlSha256"), f"{where} audit.source.xmlSha256")
        if _sha(pin["auditXmlSha256"], f"{where}.auditXmlSha256") != xml_sha:
            _fail(f"{where}.auditXmlSha256 does not match the legacy audit source")
        if xml_sha == current_xml_sha:
            _fail(f"{where} audits the current streets.xml, not a previous build")
        surface_source = _object(source.get("surfaceSource"), f"{where} audit.source.surfaceSource")
        inputs = _array(surface_source.get("inputs"), f"{where} audit.source.surfaceSource.inputs")
        if len(inputs) != 1 or _bounded_string(
            _object(inputs[0], f"{where} audit source input").get("layer"),
            f"{where} audit source layer", MAX_IDENTITY_STRING,
        ) != map_id:
            _fail(f"{where} audit is not the official {map_id} container")
        baseline = _object(audit.get("baseline"), f"{where} audit.baseline")
        if _integer(baseline.get("streetCount"), f"{where} audit.baseline.streetCount", 1) != street_count:
            _fail(f"{where} street count differs from the current audit; index alignment is ambiguous")
        old_streets, _ = _reconstruct_streets(audit, target_src)
        old_by_index = {street["streetIndex"]: street for street in old_streets}
        # 現行鐵路清單可以比舊版多（規則收緊，例如 42.21 起 Branch Line）；那些街道不參與認證，
        # 舊版照樣記為一般道路無妨。反過來舊版的鐵路在現行變成道路就沒有舊幾何可對，fail closed。
        if not set(by_index) <= set(old_by_index):
            _fail(f"{where} a current usable street is a railroad in the legacy audit")
        for index, now in by_index.items():
            old = old_by_index[index]
            if old["fingerprint"] == now["fingerprint"]:
                continue
            if old["fingerprint"] in current:
                _fail(f"{where} street {old['streetIndex']}: old geometry equals a current street")
            prior = legacy.get(old["fingerprint"])
            if prior is not None and prior["fingerprint"] != now["fingerprint"]:
                _fail(f"{where} street {old['streetIndex']}: old geometry maps to two current streets")
            legacy[old["fingerprint"]] = now
        sources.append({"sourceBuild": build, "xmlSha256": xml_sha})
    if len(used) != len(by_digest):
        _fail("--legacy-audit input is not pinned in approvals.legacyAudits")
    return sources, {
        fingerprint: {"width": legacy[fingerprint]["width"], "points": legacy[fingerprint]["points"]}
        for fingerprint in sorted(legacy)
    }


def candidate_evidence_hash(
    candidate: dict[str, Any], surface_fingerprint: str, xml_sha256: str
) -> str:
    candidate_id = _string(candidate.get("id"), "candidate.id")
    fields = (
        "evidenceVersion", "polyline", "polylineQ2", "length",
        "widthMedian", "widthP10", "widthP90", "coverage", "area", "bbox",
        "surfaceCounts", "dominantSurface", "surfacePurity", "connection",
        "parallelToGraphRatio", "maxGraphDistance", "confidence",
        "boundaryTruncated", "analysisStatus", "accepted", "rejectionReasons",
    )
    _exact_keys(candidate, set(fields) | {"id", "evidenceHash"},
                f"candidate {candidate_id}")
    if candidate["evidenceVersion"] != 2:
        _fail(f"candidate {candidate_id}.evidenceVersion must be 2")
    if (
        len(_array(candidate["polyline"], f"candidate {candidate_id}.polyline"))
        > MAX_CANDIDATE_POLYLINE_POINTS
        or len(_array(candidate["polylineQ2"], f"candidate {candidate_id}.polylineQ2"))
        > MAX_CANDIDATE_POLYLINE_POINTS
    ):
        _fail(
            f"candidate {candidate_id} polyline exceeds "
            f"{MAX_CANDIDATE_POLYLINE_POINTS} points"
        )
    evidence = {
        "version": 2,
        "source": {
            "surfaceFingerprint": surface_fingerprint,
            "xmlSha256": xml_sha256,
        },
        "candidate": {field: candidate[field] for field in fields},
    }
    canonical = json.dumps(
        evidence, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False
    ) + "\n"
    return hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def _validate_candidate_evidence(
    candidate: dict[str, Any],
    candidate_id: str,
    surface_fingerprint: str,
    xml_sha256: str,
    require_detailed: bool,
) -> tuple[list[float], str]:
    evidence_hash = _sha(candidate.get("evidenceHash"), f"candidate {candidate_id}.evidenceHash")
    if candidate_id != "c:" + evidence_hash:
        _fail(f"candidate id/evidenceHash mismatch: {candidate_id}")
    if candidate_evidence_hash(candidate, surface_fingerprint, xml_sha256) != evidence_hash:
        _fail(f"candidate evidence payload hash mismatch: {candidate_id}")
    analysis_status = candidate.get("analysisStatus")
    accepted = candidate.get("accepted")
    boundary = candidate.get("boundaryTruncated")
    reasons = _array(candidate.get("rejectionReasons"),
                     f"candidate {candidate_id}.rejectionReasons")
    seen_reasons: set[str] = set()
    for reason in reasons:
        if not isinstance(reason, str) or not reason or reason not in AUDIT_REJECTION_REASONS:
            _fail(f"candidate rejection reason invalid: {candidate_id}")
        if reason in seen_reasons:
            _fail(f"candidate rejection reason duplicate: {candidate_id}")
        seen_reasons.add(reason)
    if (
        analysis_status not in ("detailed", "aggregate")
        or not isinstance(accepted, bool)
        or not isinstance(boundary, bool)
    ):
        _fail(f"candidate decision fields invalid: {candidate_id}")
    if accepted != (len(reasons) == 0):
        _fail(f"candidate accepted/rejectionReasons mismatch: {candidate_id}")
    if accepted and (analysis_status != "detailed" or boundary):
        _fail(f"accepted candidate lacks detailed non-boundary evidence: {candidate_id}")
    if require_detailed and (analysis_status != "detailed" or boundary):
        _fail(f"candidate lacks detailed evidence: {candidate_id}")
    area = _integer(candidate.get("area"), f"candidate {candidate_id}.area", 16)
    length = _number(candidate.get("length"), f"candidate {candidate_id}.length")
    if length < 0:
        _fail(f"candidate {candidate_id}.length must be >= 0")
    p10 = _number(candidate.get("widthP10"), f"candidate {candidate_id}.widthP10")
    median = _number(candidate.get("widthMedian"), f"candidate {candidate_id}.widthMedian")
    p90 = _number(candidate.get("widthP90"), f"candidate {candidate_id}.widthP90")
    if p10 < 0 or p10 > median or median > p90:
        _fail(f"candidate {candidate_id} width quantiles invalid")
    for field in ("coverage", "surfacePurity", "parallelToGraphRatio"):
        value = _number(candidate.get(field), f"candidate {candidate_id}.{field}")
        if value < 0 or value > 1:
            _fail(f"candidate {candidate_id}.{field} outside 0..1")
    max_distance = _number(
        candidate.get("maxGraphDistance"), f"candidate {candidate_id}.maxGraphDistance"
    )
    if max_distance < 0:
        _fail(f"candidate {candidate_id}.maxGraphDistance must be >= 0")
    if candidate.get("dominantSurface") not in AUDIT_SURFACES:
        _fail(f"candidate {candidate_id}.dominantSurface invalid")
    if candidate.get("confidence") not in ("high", "low", "none"):
        _fail(f"candidate {candidate_id}.confidence invalid")
    bbox = _object(candidate.get("bbox"), f"candidate {candidate_id}.bbox")
    _exact_keys(bbox, {"x0", "y0", "x1", "y1"}, f"candidate {candidate_id}.bbox")
    bx0 = _number(bbox["x0"], "bbox.x0")
    by0 = _number(bbox["y0"], "bbox.y0")
    bx1 = _number(bbox["x1"], "bbox.x1")
    by1 = _number(bbox["y1"], "bbox.y1")
    if bx0 > bx1 or by0 > by1:
        _fail(f"candidate {candidate_id}.bbox ordering invalid")
    connection = _object(candidate.get("connection"), f"candidate {candidate_id}.connection")
    _exact_keys(connection, {
        "d0", "d1", "endsWithin8", "nearestSegment0Id", "nearestSegment1Id", "sameSegment",
    }, f"candidate {candidate_id}.connection")
    if (
        _number(connection["d0"], "connection.d0") < 0
        or _number(connection["d1"], "connection.d1") < 0
    ):
        _fail(f"candidate {candidate_id} connection distance invalid")
    ends = _integer(connection["endsWithin8"], "connection.endsWithin8")
    if ends > 2 or not isinstance(connection["sameSegment"], bool):
        _fail(f"candidate {candidate_id} connection fields invalid")
    for key in ("nearestSegment0Id", "nearestSegment1Id"):
        if connection[key] is not None and not isinstance(connection[key], str):
            _fail(f"candidate {candidate_id}.{key} invalid")
    surface_counts = _object(
        candidate.get("surfaceCounts"), f"candidate {candidate_id}.surfaceCounts"
    )
    _exact_keys(surface_counts, set(AUDIT_SURFACES),
                f"candidate {candidate_id}.surfaceCounts")
    classify_surface(surface_counts, f"candidate {candidate_id}.surfaceCounts")
    polyline = _array(candidate.get("polyline"), f"candidate {candidate_id}.polyline")
    polyline_q2 = _array(candidate.get("polylineQ2"), f"candidate {candidate_id}.polylineQ2")
    if len(polyline) < 2 or len(polyline) != len(polyline_q2):
        _fail(f"candidate polyline/polylineQ2 length mismatch: {candidate_id}")
    points: list[float] = []
    previous: tuple[int, int] | None = None
    for point_pos, raw_point in enumerate(polyline):
        point = _array(raw_point, f"candidate {candidate_id}.polyline[{point_pos}]")
        if len(point) != 2:
            _fail(f"candidate {candidate_id} polyline points must be [x,y]")
        x = _number(point[0], f"candidate {candidate_id} x")
        y = _number(point[1], f"candidate {candidate_id} y")
        qpoint_raw = _array(
            polyline_q2[point_pos], f"candidate {candidate_id}.polylineQ2[{point_pos}]"
        )
        if len(qpoint_raw) != 2 or any(isinstance(value, bool) or not isinstance(value, int)
                                      for value in qpoint_raw):
            _fail(f"candidate {candidate_id} polylineQ2 must contain integer pairs")
        qpoint = (qpoint_raw[0], qpoint_raw[1])
        if qpoint != (quantize(x, "candidate x"), quantize(y, "candidate y")):
            _fail(f"candidate {candidate_id} polyline/polylineQ2 mismatch")
        if qpoint == previous:
            continue
        previous = qpoint
        points.extend((qpoint[0] / 2, qpoint[1] / 2))
    if len(points) < 4:
        _fail(f"candidate collapses after quantization: {candidate_id}")
    return points, evidence_hash


def _candidate_operations(
    audit: dict[str, Any],
    approvals: list[Any],
    rejections: list[Any],
    target_src: str,
    surface_fingerprint: str,
    xml_sha256: str,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]], list[dict[str, str]]]:
    analysis = _object(audit.get("candidateAnalysis"), "audit.candidateAnalysis")
    if analysis.get("status") != "ok":
        _fail("candidateAnalysis.status must be 'ok'")
    candidate_values = _array(audit.get("candidates"), "audit.candidates")
    if len(candidate_values) > MAX_CANDIDATES:
        _fail(f"audit.candidates exceeds {MAX_CANDIDATES}")
    candidates: dict[str, dict[str, Any]] = {}
    provisional: set[str] = set()
    for pos, raw_candidate in enumerate(candidate_values):
        candidate = _object(raw_candidate, f"audit.candidates[{pos}]")
        candidate_id = _string(candidate.get("id"), f"audit.candidates[{pos}].id")
        if candidate_id in candidates:
            _fail(f"duplicate audit candidate id: {candidate_id}")
        _validate_candidate_evidence(
            candidate, candidate_id, surface_fingerprint, xml_sha256, False
        )
        candidates[candidate_id] = candidate
        if candidate.get("accepted") is True:
            provisional.add(candidate_id)
    if _integer(analysis.get("acceptedCount"), "audit.candidateAnalysis.acceptedCount") != len(provisional):
        _fail("candidateAnalysis.acceptedCount mismatch")

    adds: list[dict[str, Any]] = []
    bridges: list[dict[str, Any]] = []
    decided: set[str] = set()
    approval_keys = {
        "id", "evidenceHash", "operation", "surface", "width", "searchable", "reason"
    }
    for pos, raw_approval in enumerate(approvals):
        where = f"approvals.approvedCandidates[{pos}]"
        approval = _object(raw_approval, where)
        _exact_keys(approval, approval_keys, where)
        candidate_id = _string(approval["id"], f"{where}.id")
        if candidate_id in decided:
            _fail(f"candidate decision alias/duplicate: {candidate_id}")
        if candidate_id not in provisional:
            _fail(f"approval is not a provisionally accepted candidate: {candidate_id}")
        decided.add(candidate_id)
        operation_kind = _string(approval["operation"], f"{where}.operation")
        if operation_kind not in ("add", "bridge"):
            _fail(f"{where}.operation must be 'add' or 'bridge'")
        candidate = candidates[candidate_id]
        points, candidate_hash = _validate_candidate_evidence(
            candidate, candidate_id, surface_fingerprint, xml_sha256, True
        )
        _validate_points(points, f"candidate {candidate_id}.polylineQ2")
        if candidate_hash != _sha(approval["evidenceHash"], f"{where}.evidenceHash"):
            _fail(f"candidate evidence hash mismatch: {candidate_id}")
        surface = _string(approval["surface"], f"{where}.surface")
        if surface not in SURFACES:
            _fail(f"{where}.surface is invalid: {surface}")
        width = _number(approval["width"], f"{where}.width", positive=True)
        if width < 2 or width > 8:
            _fail(f"{where}.width must be within audited road bounds 2..8")
        searchable = approval["searchable"]
        if searchable is not False:
            _fail(f"{where}.searchable must be false")
        reason = _bounded_string(approval["reason"], f"{where}.reason", MAX_REASON_STRING)
        operation = {
            "id": candidate_id,
            "src": target_src,
            "width": width,
            "surface": surface,
            "searchable": searchable,
            "reason": reason,
            "points": _simplify_polyline(points, OPERATION_SIMPLIFY_EPSILON),
        }
        (adds if operation_kind == "add" else bridges).append(operation)

    rejected: list[dict[str, str]] = []
    rejection_keys = {"id", "evidenceHash", "reason"}
    for pos, raw_rejection in enumerate(rejections):
        where = f"approvals.rejectedCandidates[{pos}]"
        rejection = _object(raw_rejection, where)
        _exact_keys(rejection, rejection_keys, where)
        candidate_id = _string(rejection["id"], f"{where}.id")
        if candidate_id in decided:
            _fail(f"candidate decision alias/duplicate: {candidate_id}")
        if candidate_id not in provisional:
            _fail(f"rejection is not a provisionally accepted candidate: {candidate_id}")
        decided.add(candidate_id)
        candidate = candidates[candidate_id]
        evidence_hash = _sha(rejection["evidenceHash"], f"{where}.evidenceHash")
        _, candidate_hash = _validate_candidate_evidence(
            candidate, candidate_id, surface_fingerprint, xml_sha256, True
        )
        if candidate_hash != evidence_hash:
            _fail(f"candidate evidence hash mismatch: {candidate_id}")
        rejected.append({
            "id": candidate_id,
            "reason": _bounded_string(rejection["reason"], f"{where}.reason", MAX_REASON_STRING),
        })

    undecided = sorted(provisional - decided)
    if undecided:
        _fail(f"provisionally accepted candidates lack a decision: {undecided[:10]}")
    adds.sort(key=lambda operation: operation["id"])
    bridges.sort(key=lambda operation: operation["id"])
    rejected.sort(key=lambda item: item["id"])
    return adds, bridges, rejected

def _manual_operations(
    approvals: dict[str, Any], target_src: str, taken_ids: set[str],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """人工核准道路：補齊未形成自動稽核候選的道路幾何。

    視覺可見但 class 層無訊號的路（如與周圍曠野同 dirt 材質的土徑）稽核
    row-span 找不到——訊號不存在於表面類別資料。此入口允許人工提供折線，
    id 必須 `m:` 前綴與 candidate 證據空間分離；寬度從 2 到既有道路資料上限 MAX_WIDTH；
    searchable 預設強制 false；只有帶 name（官方原街名，build_payload 對官方 streets.xml
    驗證）時才允許 true，用來接手「整條官方街都被取代」的街名搜尋。points 過同一套幾何
    驗證與 DP 簡化。
    """
    manual_values = _array(approvals["manualRoads"], "approvals.manualRoads")
    adds: list[dict[str, Any]] = []
    bridges: list[dict[str, Any]] = []
    keys = {"id", "operation", "points", "width", "surface", "searchable", "reason"}
    seen: set[str] = set()
    for pos, raw_entry in enumerate(manual_values):
        where = f"approvals.manualRoads[{pos}]"
        entry = _object(raw_entry, where)
        if "name" in entry:
            _exact_keys(entry, keys | {"name"}, where)
        else:
            _exact_keys(entry, keys, where)
        identity = _bounded_string(entry["id"], f"{where}.id", MAX_IDENTITY_STRING)
        if not identity.startswith("m:"):
            _fail(f"{where}.id must use the m: manual prefix")
        if identity in seen or identity in taken_ids:
            _fail(f"manual road id alias/duplicate: {identity}")
        seen.add(identity)
        operation_kind = _string(entry["operation"], f"{where}.operation")
        if operation_kind not in ("add", "bridge"):
            _fail(f"{where}.operation must be 'add' or 'bridge'")
        points = [
            _number(value, f"{where}.points[{index}]")
            for index, value in enumerate(_array(entry["points"], f"{where}.points"))
        ]
        _validate_points(points, f"{where}.points")
        surface = _string(entry["surface"], f"{where}.surface")
        if surface not in SURFACES:
            _fail(f"{where}.surface is invalid: {surface}")
        width = _road_width(entry["width"], f"{where}.width")
        if width < 2:
            _fail(f"{where}.width must be at least 2")
        name = None
        if "name" in entry:
            name = _bounded_string(entry["name"], f"{where}.name", MAX_IDENTITY_STRING)
            if entry["searchable"] is not True:
                _fail(f"{where}.name requires searchable true (name only serves street search)")
        elif entry["searchable"] is not False:
            _fail(f"{where}.searchable must be false unless an official street name is given")
        reason = _bounded_string(entry["reason"], f"{where}.reason", MAX_REASON_STRING)
        operation = {
            "id": identity,
            "src": target_src,
            "width": width,
            "surface": surface,
            "searchable": name is not None,
            "reason": reason,
            "points": _simplify_polyline(points, OPERATION_SIMPLIFY_EPSILON),
        }
        if name is not None:
            operation["name"] = name
        (adds if operation_kind == "add" else bridges).append(operation)
    return adds, bridges


def _validate_manual_names(
    named: list[dict[str, Any]], streets_raw: bytes | None, xml_sha: str,
    street_count: int, streets: list[dict[str, Any]], removes: set[str],
) -> None:
    """帶名人工道路只能接手「整條被取代」的官方街名，名稱逐字取自官方 streets.xml。

    官方街只要還有一段保留，那段就照常提供搜尋——人工線再帶同名會在索引裡重複；
    名稱不在官方 XML＝造名。兩者都拒收。
    """
    if not named:
        return
    if streets_raw is None:
        _fail("named manualRoads require --streets <official streets.xml>")
    if hashlib.sha256(streets_raw).hexdigest() != xml_sha:
        _fail("--streets SHA-256 does not match audit.source.xmlSha256")
    try:
        root = ET.fromstring(streets_raw)
    except ET.ParseError as exc:
        _fail(f"--streets XML parse failed: {exc}")
    elements = [child for child in root if child.tag == "street"]
    if len(elements) != street_count:
        _fail(f"--streets street count {len(elements)} != audit streetCount {street_count}")
    by_name: dict[str, list[dict[str, Any]]] = {}
    for street in streets:
        element = elements[street["streetIndex"]]
        point = element.find("./points/point")
        if point is None or (
            quantize(float(point.get("x", "nan")), "--streets x") != quantize(street["points"][0], "x")
            or quantize(float(point.get("y", "nan")), "--streets y") != quantize(street["points"][1], "y")
        ):
            _fail(f"--streets street {street['streetIndex']} does not match the audit geometry")
        by_name.setdefault(element.get("name", ""), []).append(street)
    seen: set[str] = set()
    for operation in named:
        name = operation["name"]
        where = f"manual road {operation['id']} name {name!r}"
        if name in seen:
            _fail(f"{where}: another searchable manual road already carries this name")
        seen.add(name)
        official = by_name.get(name)
        if not official:
            _fail(f"{where} is not an official (non-railroad) street name")
        for street in official:
            kept = [
                index for index in range(len(street["surfaces"]))
                if segment_id(street["compact"], index) not in removes
            ]
            if kept:
                _fail(
                    f"{where}: official streetIndex {street['streetIndex']} keeps segments "
                    f"{kept[:5]} searchable; only fully replaced streets may pass their name on"
                )


def build_payload(
    audit: dict[str, Any], approvals: dict[str, Any], audit_raw: bytes,
    approvals_raw: bytes, generator_raw: bytes,
    legacy_inputs: list[tuple[dict[str, Any], bytes]] | None = None,
    streets_raw: bytes | None = None,
) -> dict[str, Any]:
    if audit.get("schemaVersion") != 1:
        _fail("audit.schemaVersion must be road-audit-v1 (1)")
    approval_keys = {
        "schemaVersion", "targetSrc", "mapId", "sourceBuild", "auditSha256",
        "auditXmlSha256", "auditSurfaceFingerprint", "approvedCandidates",
        "rejectedCandidates", "remove", "width", "surface", "manualRoads",
    }
    if "legacyAudits" in approvals:
        approval_keys.add("legacyAudits")
    _exact_keys(approvals, approval_keys, "approvals")
    if approvals["schemaVersion"] != 1:
        _fail("approvals.schemaVersion must be 1")
    audit_digest = hashlib.sha256(audit_raw).hexdigest()
    if _sha(approvals["auditSha256"], "approvals.auditSha256") != audit_digest:
        _fail("approval auditSha256 does not match audit bytes")

    source_obj = _object(audit.get("source"), "audit.source")
    xml_sha = _sha(source_obj.get("xmlSha256"), "audit.source.xmlSha256")
    surface_fingerprint = _sha(
        source_obj.get("surfaceFingerprint"), "audit.source.surfaceFingerprint"
    )
    if _sha(approvals["auditXmlSha256"], "approvals.auditXmlSha256") != xml_sha:
        _fail("approval auditXmlSha256 does not match audit source")
    if _sha(
        approvals["auditSurfaceFingerprint"], "approvals.auditSurfaceFingerprint"
    ) != surface_fingerprint:
        _fail("approval auditSurfaceFingerprint does not match audit source")
    surface_source = _object(source_obj.get("surfaceSource"), "audit.source.surfaceSource")
    source_build = _bounded_string(
        surface_source.get("pzBuild"), "audit.source.surfaceSource.pzBuild", MAX_IDENTITY_STRING
    )
    if _bounded_string(
        approvals["sourceBuild"], "approvals.sourceBuild", MAX_IDENTITY_STRING
    ) != source_build:
        _fail("approval sourceBuild does not match audit source")
    inputs = _array(surface_source.get("inputs"), "audit.source.surfaceSource.inputs")
    if len(inputs) != 1:
        _fail("official RoadPatch audit must contain exactly one source input")
    map_id = _bounded_string(
        _object(inputs[0], "audit source input").get("layer"),
        "audit source layer", MAX_IDENTITY_STRING,
    )
    if _bounded_string(approvals["mapId"], "approvals.mapId", MAX_IDENTITY_STRING) != map_id:
        _fail("approval mapId does not match audit source input")
    target_src = _bounded_string(
        approvals["targetSrc"], "approvals.targetSrc", MAX_IDENTITY_STRING
    )
    if target_src != map_id:
        _fail("approval targetSrc must identify the audited official container")

    streets, surface_by_segment = _reconstruct_streets(audit, target_src)
    legacy_sources, legacy = _legacy_geometry(
        approvals, legacy_inputs or [], streets,
        _integer(_object(audit.get("baseline"), "audit.baseline").get("streetCount"),
                 "audit.baseline.streetCount", 1),
        map_id, target_src, xml_sha,
    )
    approved_candidates = _array(
        approvals["approvedCandidates"], "approvals.approvedCandidates"
    )
    rejected_candidates = _array(
        approvals["rejectedCandidates"], "approvals.rejectedCandidates"
    )
    adds, bridges, rejected = _candidate_operations(
        audit, approved_candidates, rejected_candidates, target_src,
        surface_fingerprint, xml_sha,
    )
    manual_adds, manual_bridges = _manual_operations(
        approvals, target_src,
        {op["id"] for op in adds} | {op["id"] for op in bridges},
    )
    adds.extend(manual_adds)
    bridges.extend(manual_bridges)
    adds.sort(key=lambda operation: operation["id"])
    bridges.sort(key=lambda operation: operation["id"])

    remove_values = _array(approvals["remove"], "approvals.remove")
    removes: list[str] = []
    remove_seen: set[str] = set()
    for pos, value in enumerate(remove_values):
        identity = _string(value, f"approvals.remove[{pos}]")
        if identity in remove_seen:
            _fail(f"remove alias/duplicate: {identity}")
        if identity not in surface_by_segment:
            _fail(f"remove references unknown official segment: {identity}")
        remove_seen.add(identity)
        removes.append(identity)
    removes.sort()
    _validate_manual_names(
        [op for op in manual_adds + manual_bridges if "name" in op], streets_raw, xml_sha,
        _integer(_object(audit.get("baseline"), "audit.baseline").get("streetCount"),
                 "audit.baseline.streetCount", 1),
        streets, remove_seen,
    )

    width_values = _array(approvals["width"], "approvals.width")
    widths: dict[str, float] = {}
    for pos, raw_width in enumerate(width_values):
        where = f"approvals.width[{pos}]"
        item = _object(raw_width, where)
        _exact_keys(item, {"id", "width"}, where)
        identity = _string(item["id"], f"{where}.id")
        if identity in widths:
            _fail(f"width alias/duplicate: {identity}")
        if identity not in surface_by_segment:
            _fail(f"width references unknown official segment: {identity}")
        widths[identity] = _road_width(item["width"], f"{where}.width")

    surface_values = _array(approvals["surface"], "approvals.surface")
    surface_overrides = dict(surface_by_segment)
    manual_seen: set[str] = set()
    for pos, raw_surface in enumerate(surface_values):
        where = f"approvals.surface[{pos}]"
        item = _object(raw_surface, where)
        _exact_keys(item, {"id", "surface"}, where)
        identity = _string(item["id"], f"{where}.id")
        if identity in manual_seen:
            _fail(f"surface alias/duplicate: {identity}")
        if identity not in surface_by_segment:
            _fail(f"surface references unknown official segment: {identity}")
        surface = _string(item["surface"], f"{where}.surface")
        if surface not in SURFACES:
            _fail(f"{where}.surface is invalid: {surface}")
        manual_seen.add(identity)
        surface_overrides[identity] = surface

    payload: dict[str, Any] = {
        "schemaVersion": 1,
        "targetSrc": target_src,
        "mapId": map_id,
        "sourceBuild": source_build,
        "xmlSha256": xml_sha,
        "surfaceFingerprint": surface_fingerprint,
        "auditSha256": audit_digest,
        "approvalsSha256": hashlib.sha256(approvals_raw).hexdigest(),
        "generatorSha256": hashlib.sha256(generator_raw).hexdigest(),
        "rejectedCandidateCount": len(rejected),
        "rejectedEvidenceHash": canonical_sha256(rejected),
        "geometrySet": {
            street["fingerprint"]: street["compact"]
            for street in sorted(streets, key=lambda item: item["fingerprint"])
        },
        "legacySources": legacy_sources,
        "legacy": legacy,
        "remove": removes,
        "add": adds,
        "bridge": bridges,
        "width": [{"id": identity, "value": widths[identity]} for identity in sorted(widths)],
        "surface": [
            {"id": identity, "value": surface_overrides[identity]}
            for identity in sorted(surface_overrides)
        ],
    }
    payload["tag"] = canonical_sha256(payload)
    return payload


def _lua_string(value: str) -> str:
    if any(ord(char) < 0x20 for char in value):
        _fail("Lua strings must not contain C0 controls")
    # Kahlua 的 LexState 逐 char 以 (byte)c 存、字串結束才用 UTF-8 解回（LexState.java:194-199、245-247）：
    # 直接寫進字面值的非 ASCII 會被截壞，寫成 UTF-8 位元組的 \ddd（固定三位）才會解回原字
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return '"' + "".join(
        char if ord(char) < 0x80 else "".join(f"\\{byte:03d}" for byte in char.encode("utf-8"))
        for char in escaped
    ) + '"'


def _lua_number(value: float | int) -> str:
    number = float(value)
    if number.is_integer():  # also normalises -0.0 to "0"
        return str(int(number))
    return format(number, ".15g")


def _render_street_operation(operation: dict[str, Any]) -> str:
    points = ", ".join(_lua_number(value) for value in operation["points"])
    searchable = "true" if operation["searchable"] else "false"
    return (
        "        { id = " + _lua_string(operation["id"])
        + ", src = " + _lua_string(operation["src"])
        + ", width = " + _lua_number(operation["width"])
        + ", surface = " + _lua_string(operation["surface"])
        + (", name = " + _lua_string(operation["name"]) if "name" in operation else "")
        + ", searchable = " + searchable
        + ", reason = " + _lua_string(operation["reason"])
        + ", pts = { " + points + " } },"
    )


def render_lua(payload: dict[str, Any]) -> str:
    lines = [
        "-- MinidoracatMiniMapRoadPatches.lua",
        "-- 由 scripts/gen_road_patches.py 從 road-audit-v1 與人工批准清單產生；請勿手改。",
        "-- 重生：python scripts/gen_road_patches.py --audit target/road-audit-v2.json"
        " --legacy-audit target/road-audit-v2-42.20.4.json"
        " --streets \"<PZ>/media/maps/Muldraugh, KY/streets.xml\"",
        "-- runtime 驗官方來源或已認證載體的 full-q2-geometry+width set；不讀 XML、不計算 SHA。",
        "",
        "MinidoracatMiniMapRoadPatches = {",
        f"    schemaVersion = {payload['schemaVersion']},",
        f"    targetSrc = {_lua_string(payload['targetSrc'])},",
        f"    mapId = {_lua_string(payload['mapId'])},",
        f"    sourceBuild = {_lua_string(payload['sourceBuild'])},",
        f"    xmlSha256 = {_lua_string(payload['xmlSha256'])},",
        f"    surfaceFingerprint = {_lua_string(payload['surfaceFingerprint'])},",
        f"    auditSha256 = {_lua_string(payload['auditSha256'])},",
        f"    rejectedCandidateCount = {payload['rejectedCandidateCount']},",
        f"    approvalsSha256 = {_lua_string(payload['approvalsSha256'])},",
        f"    generatorSha256 = {_lua_string(payload['generatorSha256'])},",
        f"    rejectedEvidenceHash = {_lua_string(payload['rejectedEvidenceHash'])},",
        f"    tag = {_lua_string(payload['tag'])},",
        f"    geometryCount = {len(payload['geometrySet'])},",
        "    geometrySet = {",
    ]
    for geometry, compact in payload["geometrySet"].items():
        lines.append(
            f"        [{_lua_string(geometry)}] = {_lua_string(compact)},"
        )
    lines.append("    },")
    lines.append("    legacySources = {")
    for source in payload["legacySources"]:
        lines.append(
            f"        {{ sourceBuild = {_lua_string(source['sourceBuild'])}, "
            f"xmlSha256 = {_lua_string(source['xmlSha256'])} }},"
        )
    lines.extend(["    },", f"    legacyCount = {len(payload['legacy'])},", "    legacy = {"])
    for geometry, item in payload["legacy"].items():
        points = ", ".join(_lua_number(value) for value in item["points"])
        lines.append(
            f"        [{_lua_string(geometry)}] = {{ width = {_lua_number(item['width'])}, "
            f"pts = {{ {points} }} }},"
        )
    lines.extend(["    },", f"    removeCount = {len(payload['remove'])},", "    remove = {"])
    for identity in payload["remove"]:
        lines.append(f"        {_lua_string(identity)},")
    lines.extend(["    },", f"    addCount = {len(payload['add'])},", "    add = {"])
    lines.extend(_render_street_operation(operation) for operation in payload["add"])
    lines.extend(["    },", f"    bridgeCount = {len(payload['bridge'])},", "    bridge = {"])
    lines.extend(_render_street_operation(operation) for operation in payload["bridge"])
    lines.extend(["    },", f"    widthCount = {len(payload['width'])},", "    width = {"])
    for item in payload["width"]:
        lines.append(
            f"        {{ id = {_lua_string(item['id'])}, value = {_lua_number(item['value'])} }},"
        )
    lines.extend(["    },", f"    surfaceCount = {len(payload['surface'])},", "    surface = {"])
    for item in payload["surface"]:
        lines.append(
            f"        {{ id = {_lua_string(item['id'])}, value = {_lua_string(item['value'])} }},"
        )
    lines.extend(["    },", "}", ""])
    body = "\n".join(lines)
    digest = hashlib.sha256(body.encode("utf-8")).hexdigest()
    return f"-- generated-body-sha256: {digest}\n" + body


def _same_file_or_path(left: Path, right: Path) -> bool:
    try:
        if left.exists() and right.exists() and os.path.samefile(left, right):
            return True
    except OSError:
        pass
    return left.resolve(strict=False) == right.resolve(strict=False)


def reject_path_aliases(
    audit_path: Path, approvals_path: Path, out_path: Path, legacy_paths: tuple[Path, ...] = ()
) -> None:
    named = [("audit", audit_path), ("approvals", approvals_path), ("output", out_path)]
    named.extend((f"legacy audit {pos}", path) for pos, path in enumerate(legacy_paths))
    for left_pos, (left_name, left) in enumerate(named):
        for right_name, right in named[left_pos + 1:]:
            if _same_file_or_path(left, right):
                _fail(f"path alias rejected: {left_name} and {right_name} refer to the same file")


def atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_path, path)
    except BaseException:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass
        raise

def generate(
    audit_path: Path, approvals_path: Path, out_path: Path, legacy_paths: tuple[Path, ...] = (),
    streets_path: Path | None = None,
) -> dict[str, Any]:
    reject_path_aliases(audit_path, approvals_path, out_path, legacy_paths)
    audit, audit_raw = _load_json(audit_path, "audit", MAX_AUDIT_BYTES)
    approvals, approvals_raw = _load_json(
        approvals_path, "approvals", MAX_APPROVAL_BYTES
    )
    legacy_inputs = [
        _load_json(path, f"legacy audit {pos}", MAX_AUDIT_BYTES)
        for pos, path in enumerate(legacy_paths)
    ]
    streets_raw = None
    if streets_path is not None:
        if streets_path.stat().st_size > MAX_AUDIT_BYTES:
            _fail(f"--streets exceeds {MAX_AUDIT_BYTES} bytes")
        streets_raw = streets_path.read_bytes()
    payload = build_payload(
        audit, approvals, audit_raw, approvals_raw, Path(__file__).read_bytes(), legacy_inputs,
        streets_raw,
    )
    atomic_write(out_path, render_lua(payload))
    return payload


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--audit", type=Path, default=DEFAULT_AUDIT)
    parser.add_argument("--approvals", type=Path, default=DEFAULT_APPROVALS)
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--legacy-audit", type=Path, action="append", default=[],
                        help="previous official audit pinned in approvals.legacyAudits")
    parser.add_argument("--streets", type=Path, default=None,
                        help="official streets.xml (SHA pinned by the audit); "
                             "required when a manual road carries name")
    args = parser.parse_args()
    try:
        payload = generate(args.audit, args.approvals, args.out, tuple(args.legacy_audit),
                           args.streets)
    except GenerationError as exc:
        parser.error(str(exc))
    print(f"source build: {payload['sourceBuild']}")
    print(f"target source: {payload['targetSrc']}")
    print(f"usable geometries: {len(payload['geometrySet'])}")
    print(f"legacy geometries: {len(payload['legacy'])} from "
          f"{[source['sourceBuild'] for source in payload['legacySources']]}")
    print(f"surface overrides: {len(payload['surface'])}")
    print(f"candidate rejections: {payload['rejectedCandidateCount']}")
    print(
        "approved operations: "
        f"remove={len(payload['remove'])} add={len(payload['add'])} "
        f"bridge={len(payload['bridge'])} width={len(payload['width'])}"
    )
    print(f"output: {args.out}")


if __name__ == "__main__":
    main()
