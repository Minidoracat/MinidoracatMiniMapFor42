#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""官方路網稽核器（Phase B）：只讀 streets.xml + road-surfaces-v1.json。

不解析地圖 binary；B42 lot 格式的唯一 decoder 在 MapRendering。本工具用
Python stdlib 解析 XML／JSON，產出 canonical `road-audit-v1.json`（稽核報告，
不是 runtime patch）。

XML 語意對齊 WorldMapStreetsXML.java:19-117／WorldMapStreet.java
（name／width／points；version 必須為 1；根下非 street 元素視為格式錯誤）。
路面 class 只消費 MapRendering 的固定表，不依 tile 名重分類：
unknown（含 carpentry_02 木地板）與 natural 不得當缺路 candidate；
curb 單獨（中位寬 < 2 格）亦不得 accepted。

用法：
    python scripts/audit_streets.py --streets FILE.xml --surfaces FILE.json --out FILE.json
    python scripts/audit_streets.py --streets FILE.xml --surfaces FILE.json --out FILE.json --preview FILE.geojson
    python scripts/audit_streets.py ... --max-candidate-pixels 2000000
全圖 dirt-candidate 可能數百萬格；超 --max-candidate-pixels 時仍寫 topology／streetSamples，
但 candidateAnalysis.status=skipped（candidates=[] 不是「沒有缺路」）。請改餵 region JSON。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

SCHEMA_VERSION = 1
CELL_SIZE = 256
CELL_SQUARES = CELL_SIZE * CELL_SIZE
CLASSES = ("unknown", "paved", "gravel", "dirt-candidate", "natural")
CLASS_ID = {name: i for i, name in enumerate(CLASSES)}
CANDIDATE_IDS = {CLASS_ID["paved"], CLASS_ID["gravel"], CLASS_ID["dirt-candidate"]}
MISSING = object()

# 與 NavCore.isRailroadStreet 同源：英文子串 ∪ vanilla 9 條鐵路首點幾何簽名
# （MinidoracatMiniMap_NavRoute.lua:909-926）。candidate 連通判定排除鐵路。
RAILROAD_SIGS = {
    "25396:5323",
    "25329:8953",
    "23472:20392",
    "22371:27600",
    "20284:28261",
    "1641:23707",
    "5223:28161",
    "4061:13391",
    "4476:13391",
}

GATE_LENGTH = 32.0
GATE_WIDTH_LO = 2.0
GATE_WIDTH_HI = 8.0
GATE_WIDTH_SPREAD = 3.0
GATE_COVERAGE = 0.80
GATE_CONNECT = 8.0
MIN_COMPONENT_AREA = 16
DEFAULT_MAX_CANDIDATE_PIXELS = 2000000
NEAR_ENDPOINT_LO = 0.75
KIND_ORDER = {
    "emptyName": 0,
    "short": 1,
    "zeroLength": 2,
    "duplicate": 3,
    "selfIntersection": 4,
    "nearEndpoint": 5,
    "crossing": 6,
}


class AuditError(ValueError):
    """輸入契約違反（錯 schema／RLE／XML 結構）。"""


def q2(v):
    return int(math.floor(float(v) * 2.0 + 0.5))


def r3(v):
    x = round(float(v), 3)
    # -0.0 正規化為 0.0：canonical JSON 不出現負零
    if x == 0.0:
        return 0.0
    return x


def localname(tag):
    if tag is None:
        return ""
    if "}" in tag:
        return tag.rsplit("}", 1)[-1]
    return tag


def require_keys(value, expected, label):
    if not isinstance(value, dict):
        raise AuditError("%s 必須為 object" % label)
    expected = set(expected)
    actual = set(value)
    missing = sorted(expected - actual)
    unknown = sorted(actual - expected)
    if missing or unknown:
        raise AuditError("%s 欄位不符（missing=%r unknown=%r）" % (
            label, missing, unknown))
    return value


def require_int_list(value, length, label):
    if not isinstance(value, list) or len(value) != length:
        raise AuditError("%s 必須為長度 %d 的 array" % (label, length))
    return [require_int(item, "%s[%d]" % (label, i))
            for i, item in enumerate(value)]


def dumps_canonical(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n"


def quantile(vals, p):
    if not vals:
        return 0.0
    seq = sorted(vals)
    idx = p * (len(seq) - 1)
    lo = int(math.floor(idx))
    hi = int(math.ceil(idx))
    if lo == hi:
        return float(seq[lo])
    w = idx - lo
    return float(seq[lo]) * (1.0 - w) + float(seq[hi]) * w


def dist_point_seg(px, py, ax, ay, bx, by):
    dx = bx - ax
    dy = by - ay
    l2 = dx * dx + dy * dy
    if l2 <= 1e-18:
        return math.hypot(px - ax, py - ay)
    t = ((px - ax) * dx + (py - ay) * dy) / l2
    if t < 0.0:
        t = 0.0
    elif t > 1.0:
        t = 1.0
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def orient(ax, ay, bx, by, cx, cy):
    v = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
    if v > 1e-9:
        return 1
    if v < -1e-9:
        return -1
    return 0


def _same_pt(a, b):
    return abs(a[0] - b[0]) < 1e-6 and abs(a[1] - b[1]) < 1e-6


def proper_intersect(a, b, c, d):
    if _same_pt(a, c) or _same_pt(a, d) or _same_pt(b, c) or _same_pt(b, d):
        return False
    o1 = orient(a[0], a[1], b[0], b[1], c[0], c[1])
    o2 = orient(a[0], a[1], b[0], b[1], d[0], d[1])
    o3 = orient(c[0], c[1], d[0], d[1], a[0], a[1])
    o4 = orient(c[0], c[1], d[0], d[1], b[0], b[1])
    return o1 != o2 and o3 != o4


def is_railroad(name, x0, y0):
    if isinstance(name, str) and "Railroad" in name:
        return True
    sig = "%d:%d" % (q2(x0), q2(y0))
    return sig in RAILROAD_SIGS


def street_sig(pts):
    if not pts:
        return "0:0:0:0:0"
    n = len(pts)
    x0, y0 = pts[0]
    xl, yl = pts[-1]
    return "%d:%d:%d:%d:%d" % (n, q2(x0), q2(y0), q2(xl), q2(yl))


def empty_counts():
    return {name: 0 for name in CLASSES}


def require_int(value, label):
    if type(value) is bool or type(value) is not int:
        raise AuditError("%s 必須為 int，得到 %r" % (label, value))
    return value


def _xml_int(element, attr, label):
    value = element.get(attr)
    if value is None:
        raise AuditError("%s 缺少 %s" % (label, attr))
    text = value.strip()
    digits = text[1:] if text[:1] in ("+", "-") else text
    if not digits or not digits.isdigit():
        raise AuditError("%s.%s 必須為整數，得到 %r" % (label, attr, value))
    return int(text, 10)


def _xml_float(element, attr, label):
    value = element.get(attr)
    if value is None:
        raise AuditError("%s 缺少 %s" % (label, attr))
    try:
        parsed = float(value.strip())
    except ValueError as exc:
        raise AuditError("%s.%s 必須為有限數值，得到 %r" % (
            label, attr, value)) from exc
    if not math.isfinite(parsed):
        raise AuditError("%s.%s 必須為有限數值，得到 %r" % (
            label, attr, value))
    return parsed


def parse_streets(data):
    """嚴格解析同一份已雜湊 XML bytes。"""
    try:
        root = ET.fromstring(data)
    except ET.ParseError as exc:
        raise AuditError("XML 無法解析：%s" % exc) from exc
    if localname(root.tag) != "streets":
        raise AuditError('XML 根元素必須為 "streets"，得到 %r' % localname(root.tag))
    require_keys(root.attrib, {"version"}, "streets attributes")
    if _xml_int(root, "version", "streets") != 1:
        raise AuditError("missing or invalid version")
    streets = []
    for street_index, child in enumerate(list(root)):
        name = localname(child.tag)
        if name != "street":
            raise AuditError('unrecognised element "%s"' % name)
        unknown_attrs = sorted(set(child.attrib) - {"name", "width"})
        if unknown_attrs:
            raise AuditError("street[%d] 未知 attributes：%r" % (
                street_index, unknown_attrs))
        width = _xml_int(child, "width", "street[%d]" % street_index)
        if not 1 <= width <= 64:
            raise AuditError("street[%d].width 必須介於 1..64，得到 %d" % (
                street_index, width))
        containers = list(child)
        if len(containers) != 1 or localname(containers[0].tag) != "points":
            tags = [localname(item.tag) for item in containers]
            raise AuditError("street[%d] 必須恰有一個 points，得到 %r" % (
                street_index, tags))
        points = containers[0]
        if points.attrib:
            raise AuditError("street[%d].points 不接受 attributes" % street_index)
        pts = []
        for point_index, point in enumerate(list(points)):
            if localname(point.tag) != "point":
                raise AuditError('unrecognised points element "%s"' % localname(point.tag))
            unknown_attrs = sorted(set(point.attrib) - {"x", "y"})
            if unknown_attrs:
                raise AuditError("street[%d].point[%d] 未知 attributes：%r" % (
                    street_index, point_index, unknown_attrs))
            if list(point):
                raise AuditError("street[%d].point[%d] 不接受 child tags" % (
                    street_index, point_index))
            label = "street[%d].point[%d]" % (street_index, point_index)
            pts.append((_xml_float(point, "x", label),
                        _xml_float(point, "y", label)))
        streets.append({
            "name": child.get("name", ""),
            "width": width,
            "pts": pts,
        })
    return streets


def validate_runs(runs, cell_x, cell_y):
    if not isinstance(runs, list) or not runs:
        raise AuditError("cell (%s,%s) RLE 為空，未覆蓋 65536 格" % (cell_x, cell_y))
    expected = 0
    parsed = []
    for i, run in enumerate(runs):
        if not isinstance(run, list) or len(run) != 3:
            raise AuditError("cell (%s,%s) run %d 必須為 [start,length,classId]" % (cell_x, cell_y, i))
        start = require_int(run[0], "run.start")
        length = require_int(run[1], "run.length")
        class_id = require_int(run[2], "run.classId")
        if start < expected:
            raise AuditError("RLE overlap at cell (%s,%s) start=%d expected=%d" % (
                cell_x, cell_y, start, expected))
        if start > expected:
            raise AuditError("RLE gap at cell (%s,%s) start=%d expected=%d" % (
                cell_x, cell_y, start, expected))
        if length <= 0:
            raise AuditError("RLE length 必須 > 0（cell (%s,%s) start=%d）" % (cell_x, cell_y, start))
        if start < 0 or start >= CELL_SQUARES:
            raise AuditError("start out of range: %d" % start)
        if class_id < 0 or class_id >= len(CLASSES):
            raise AuditError("classId out of range: %d" % class_id)
        end = start + length
        if end > CELL_SQUARES:
            raise AuditError("RLE out of range: start=%d length=%d" % (start, length))
        parsed.append((start, end, class_id))
        expected = end
    if expected != CELL_SQUARES:
        raise AuditError("RLE 未完整覆蓋 65536 格（cell (%s,%s) covered=%d）" % (
            cell_x, cell_y, expected))
    return parsed


def _json_object(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise AuditError("surfaces JSON 重複 key：%r" % key)
        obj[key] = value
    return obj


def _json_constant(value):
    raise AuditError("surfaces JSON 不接受非有限數值：%s" % value)


def _validate_surface_source(source, cell_keys):
    require_keys(source, {"pzBuild", "scope", "inputs"}, "source")
    pz_build = source["pzBuild"]
    if not isinstance(pz_build, str) or not pz_build.strip():
        raise AuditError("source.pzBuild 必須為非空字串")

    scope = require_keys(
        source["scope"],
        {"mode", "requestedRegion", "selectedCellCount", "bounds"},
        "source.scope")
    mode = scope["mode"]
    if mode not in ("full", "region"):
        raise AuditError("source.scope.mode 必須為 full 或 region")
    requested = scope["requestedRegion"]
    if mode == "full":
        if requested is not None:
            raise AuditError("full scope 的 requestedRegion 必須為 null")
    else:
        requested = require_int_list(requested, 4, "source.scope.requestedRegion")
        if requested[0] > requested[2] or requested[1] > requested[3]:
            raise AuditError("source.scope.requestedRegion bounds 顛倒")
    selected_count = require_int(
        scope["selectedCellCount"], "source.scope.selectedCellCount")
    if selected_count != len(cell_keys):
        raise AuditError("source.scope.selectedCellCount=%d 與 cells=%d 不一致" % (
            selected_count, len(cell_keys)))
    bounds = require_int_list(scope["bounds"], 4, "source.scope.bounds")
    expected_bounds = [
        min(cx for cx, _ in cell_keys),
        min(cy for _, cy in cell_keys),
        max(cx for cx, _ in cell_keys),
        max(cy for _, cy in cell_keys),
    ]
    if bounds != expected_bounds:
        raise AuditError("source.scope.bounds=%r 與 cells bounds=%r 不一致" % (
            bounds, expected_bounds))
    if requested is not None:
        for cx, cy in cell_keys:
            if not (requested[0] <= cx <= requested[2]
                    and requested[1] <= cy <= requested[3]):
                raise AuditError("cell (%d,%d) 超出 requestedRegion %r" % (
                    cx, cy, requested))

    inputs = source["inputs"]
    if not isinstance(inputs, list) or not inputs:
        raise AuditError("source.inputs 必須為非空 array")
    manifest_keys = set()
    last_priority = None
    for input_index, item in enumerate(inputs):
        require_keys(item, {"priority", "layer", "cells"},
                     "source.inputs[%d]" % input_index)
        priority = require_int(
            item["priority"], "source.inputs[%d].priority" % input_index)
        if last_priority is not None and priority <= last_priority:
            raise AuditError("source.inputs 必須依 priority 嚴格遞增")
        last_priority = priority
        layer = item["layer"]
        if (not isinstance(layer, str) or not layer.strip()
                or layer != layer.strip() or layer in (".", "..")
                or "/" in layer or "\\" in layer or "\x00" in layer):
            raise AuditError("source.inputs[%d].layer 必須為 map-dir basename" % input_index)
        rows = item["cells"]
        if not isinstance(rows, list) or not rows:
            raise AuditError("source.inputs[%d].cells 必須為非空 array" % input_index)
        last_coord = None
        for row_index, row in enumerate(rows):
            label = "source.inputs[%d].cells[%d]" % (input_index, row_index)
            if not isinstance(row, list) or len(row) != 4:
                raise AuditError("%s 必須為 [cx,cy,lotheader,lotpack]" % label)
            cx = require_int(row[0], label + "[0]")
            cy = require_int(row[1], label + "[1]")
            coord = (cy, cx)
            if last_coord is not None and coord <= last_coord:
                raise AuditError("source.inputs[%d].cells 必須依 y,x 排序且不得重複" %
                                 input_index)
            last_coord = coord
            if row[2] != "%d_%d.lotheader" % (cx, cy):
                raise AuditError("%s lotheader 名稱不符" % label)
            if row[3] != "world_%d_%d.lotpack" % (cx, cy):
                raise AuditError("%s lotpack 名稱不符" % label)
            manifest_keys.add((cx, cy))
    if manifest_keys != cell_keys:
        raise AuditError("source.inputs cells 與 top-level cells 不一致")
    return source


def load_surfaces(data):
    try:
        raw = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_json_object,
            parse_constant=_json_constant)
    except AuditError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise AuditError("surfaces JSON 無法解析：%s" % exc) from exc
    require_keys(
        raw,
        {"schemaVersion", "mapId", "cellSize", "classes", "source", "cells"},
        "surfaces")
    schema_version = require_int(raw["schemaVersion"], "schemaVersion")
    if schema_version != SCHEMA_VERSION:
        raise AuditError("錯 schemaVersion：%r（需要 1）" % schema_version)
    map_id = raw["mapId"]
    if not isinstance(map_id, str) or not map_id.strip():
        raise AuditError("mapId 必須為非空字串")
    cell_size = require_int(raw["cellSize"], "cellSize")
    if cell_size != CELL_SIZE:
        raise AuditError("cellSize 必須為 %d，得到 %r" % (CELL_SIZE, cell_size))
    classes = raw["classes"]
    if classes != list(CLASSES):
        raise AuditError("錯 class table：%r（需要 %r）" % (classes, list(CLASSES)))
    cells = raw["cells"]
    if not isinstance(cells, list) or not cells:
        raise AuditError("cells 必須為非空 array")
    index = {}
    last_coord = None
    for i, cell in enumerate(cells):
        require_keys(cell, {"x", "y", "runs"}, "cells[%d]" % i)
        cx = require_int(cell["x"], "cell.x")
        cy = require_int(cell["y"], "cell.y")
        coord = (cy, cx)
        if last_coord is not None and coord <= last_coord:
            raise AuditError("top-level cells 必須依 y,x 排序且不得重複")
        last_coord = coord
        index[(cx, cy)] = validate_runs(cell["runs"], cx, cy)
    source = _validate_surface_source(raw["source"], set(index))
    return {
        "mapId": map_id,
        "cellSize": CELL_SIZE,
        "cells": index,
        "source": source,
    }


class SurfaceIndex:
    def __init__(self, loaded):
        self.cell_size = loaded["cellSize"]
        self.cells = loaded["cells"]

    def at(self, wx, wy):
        ix = int(math.floor(wx))
        iy = int(math.floor(wy))
        cs = self.cell_size
        cx = ix // cs
        cy = iy // cs
        lx = ix % cs
        ly = iy % cs
        runs = self.cells.get((cx, cy))
        if runs is None:
            return MISSING
        start = ly * cs + lx
        lo = 0
        hi = len(runs)
        while lo < hi:
            mid = (lo + hi) // 2
            if runs[mid][1] <= start:
                lo = mid + 1
            else:
                hi = mid
        if lo < len(runs):
            a, b, cid = runs[lo]
            if a <= start < b:
                return cid
        raise AuditError("validated RLE lookup failed at cell (%d,%d)" % (cx, cy))


def sample_segment(surface, x0, y0, x1, y1, xml_width):
    length = math.hypot(x1 - x0, y1 - y0)
    counts = empty_counts()
    center_counts = empty_counts()
    left_counts = empty_counts()
    right_counts = empty_counts()
    n_samples = 0
    missing_count = 0
    if length <= 1e-9:
        # 退化線段：只探中心一點，長度歸零
        class_id = surface.at(x0, y0)
        if class_id is MISSING:
            missing_count = 1
        else:
            name = CLASSES[class_id]
            counts[name] += 1
            center_counts[name] += 1
        n_samples = 1
        length = 0.0
    else:
        steps = max(1, int(round(length)))
        dx = (x1 - x0) / length
        dy = (y1 - y0) / length
        nx, ny = -dy, dx
        half = float(xml_width) / 2.0
        for i in range(steps + 1):
            t = i / steps
            x = x0 + (x1 - x0) * t
            y = y0 + (y1 - y0) * t
            probes = (
                (x, y, center_counts),
                (x + nx * half, y + ny * half, left_counts),
                (x - nx * half, y - ny * half, right_counts),
            )
            for px, py, bucket in probes:
                class_id = surface.at(px, py)
                if class_id is MISSING:
                    missing_count += 1
                else:
                    name = CLASSES[class_id]
                    bucket[name] += 1
                    counts[name] += 1
                n_samples += 1
    return {
        "sampleCount": n_samples,
        "missingCount": missing_count,
        "counts": counts,
        "centerCounts": center_counts,
        "leftCounts": left_counts,
        "rightCounts": right_counts,
        "length": length,
    }


def ratios_from_counts(counts):
    total = sum(counts.values())
    out = {}
    for name in CLASSES:
        out[name] = r3((counts[name] / total) if total else 0.0)
    return out


def topology_findings(streets):
    findings = []
    sig_first = {}
    segs = []
    for i, st in enumerate(streets):
        pts = st["pts"]
        sid = street_sig(pts)
        if not str(st["name"]).strip():
            findings.append({
                "kind": "emptyName",
                "id": sid,
                "streetIndex": i,
            })
        if len(pts) < 2:
            findings.append({
                "kind": "short",
                "id": sid,
                "streetIndex": i,
                "pointCount": len(pts),
            })
            continue
        if sid in sig_first:
            findings.append({
                "kind": "duplicate",
                "id": sid,
                "streetIndex": i,
                "firstStreetIndex": sig_first[sid],
            })
        else:
            sig_first[sid] = i
        for k in range(len(pts) - 1):
            a, b = pts[k], pts[k + 1]
            if math.hypot(b[0] - a[0], b[1] - a[1]) <= 1e-4:
                findings.append({
                    "kind": "zeroLength",
                    "id": sid,
                    "streetIndex": i,
                    "segIndex": k,
                })
            segs.append((i, k, a, b, sid))
        for a in range(len(pts) - 1):
            for b in range(a + 2, len(pts) - 1):
                if proper_intersect(pts[a], pts[a + 1], pts[b], pts[b + 1]):
                    findings.append({
                        "kind": "selfIntersection",
                        "id": sid,
                        "streetIndex": i,
                        "segA": a,
                        "segB": b,
                    })

    for a in range(len(segs)):
        ia, ka, a0, a1, sa = segs[a]
        for b in range(a + 1, len(segs)):
            ib, kb, b0, b1, sb = segs[b]
            if ia == ib:
                continue
            if proper_intersect(a0, a1, b0, b1):
                findings.append({
                    "kind": "crossing",
                    "id": sa,
                    "streetIndex": ia,
                    "otherStreetIndex": ib,
                    "segA": ka,
                    "segB": kb,
                    "otherId": sb,
                })

    # (streetIndex, points, sig)：sig 預先算好，避免在 O(n²) 內圈重算
    usable = [(i, st["pts"], street_sig(st["pts"]))
              for i, st in enumerate(streets) if len(st["pts"]) >= 2]
    for i, pts, sid in usable:
        for end_slot, end_idx in enumerate((0, -1)):
            px, py = pts[end_idx]
            best = None
            for j, opts, osig in usable:
                if i == j:
                    continue
                for k in range(len(opts) - 1):
                    d = dist_point_seg(px, py, opts[k][0], opts[k][1],
                                       opts[k + 1][0], opts[k + 1][1])
                    if best is None or d < best[0]:
                        best = (d, j, osig)
            if best is not None and NEAR_ENDPOINT_LO <= best[0] <= GATE_CONNECT:
                findings.append({
                    "kind": "nearEndpoint",
                    "id": sid,
                    "streetIndex": i,
                    "end": end_slot,
                    "distance": r3(best[0]),
                    "nearStreetIndex": best[1],
                    "nearId": best[2],
                })

    findings.sort(key=lambda f: (
        KIND_ORDER.get(f["kind"], 99),
        f.get("streetIndex", 0),
        f.get("segIndex", f.get("segA", f.get("end", 0))),
        f.get("otherStreetIndex", 0),
        f.get("id", ""),
    ))
    return findings


def raw_exact_vertex_components(streets):
    parent = {}

    def find(a):
        parent.setdefault(a, a)
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    heads = []
    for st in streets:
        pts = st["pts"]
        if len(pts) < 2:
            continue
        keys = [(q2(x), q2(y)) for x, y in pts]
        for i in range(len(keys) - 1):
            union(keys[i], keys[i + 1])
        heads.append(keys[0])
    sizes = {}
    for key in heads:
        # 只合併 XML 原始頂點；不宣稱等同 runtime crossing/snap topology。
        root = find(key)
        sizes[root] = sizes.get(root, 0) + 1
    component_sizes = sorted(sizes.values(), reverse=True)
    return len(component_sizes), component_sizes


def clip_segment_to_rect(x0, y0, x1, y1, minx, miny, maxx, maxy):
    """Liang-Barsky clip；完全不碰 supplied bounds 的線段不進 candidate 工作。"""
    dx = x1 - x0
    dy = y1 - y0
    lo = 0.0
    hi = 1.0
    for p, q in (
            (-dx, x0 - minx),
            (dx, maxx - x0),
            (-dy, y0 - miny),
            (dy, maxy - y0)):
        if abs(p) <= 1e-18:
            if q < 0.0:
                return None
            continue
        t = q / p
        if p < 0.0:
            lo = max(lo, t)
        else:
            hi = min(hi, t)
        if lo > hi:
            return None
    return (x0 + lo * dx, y0 + lo * dy,
            x0 + hi * dx, y0 + hi * dy)


def paint_coverage(streets, bounds):
    covered = set()
    minx, miny, maxx, maxy = bounds
    for st in streets:
        pts = st["pts"]
        if len(pts) < 2 or is_railroad(st["name"], pts[0][0], pts[0][1]):
            continue
        radius = float(st["width"]) / 2.0
        r2_tol = radius * radius + 0.05  # 半徑平方 + 邊界容差
        ri = int(math.ceil(radius))
        for i in range(len(pts) - 1):
            clipped = clip_segment_to_rect(
                pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1],
                minx - radius - 1.0, miny - radius - 1.0,
                maxx + radius + 1.0, maxy + radius + 1.0)
            if clipped is None:
                continue
            x0, y0, x1, y1 = clipped
            length = math.hypot(x1 - x0, y1 - y0)
            steps = max(1, int(math.ceil(length * 2.0)))
            for step in range(steps + 1):
                t = step / steps
                x = x0 + (x1 - x0) * t
                y = y0 + (y1 - y0) * t
                cx = int(math.floor(x))
                cy = int(math.floor(y))
                for dy in range(-ri, ri + 1):
                    sy = cy + dy
                    if sy < miny or sy > maxy:
                        continue
                    ey = (sy + 0.5 - y) ** 2
                    if ey > r2_tol:
                        continue
                    for dx in range(-ri, ri + 1):
                        sx = cx + dx
                        if sx < minx or sx > maxx:
                            continue
                        if ey + (sx + 0.5 - x) ** 2 <= r2_tol:
                            covered.add((sx, sy))
    return covered


def graph_segments(streets, bounds):
    """candidate 連通判定只保留 supplied bounds 周圍 8 格內的非鐵路線段。"""
    minx, miny, maxx, maxy = bounds
    segs = []
    for st in streets:
        pts = st["pts"]
        if len(pts) < 2 or is_railroad(st["name"], pts[0][0], pts[0][1]):
            continue
        for k in range(len(pts) - 1):
            clipped = clip_segment_to_rect(
                pts[k][0], pts[k][1], pts[k + 1][0], pts[k + 1][1],
                minx - GATE_CONNECT, miny - GATE_CONNECT,
                maxx + GATE_CONNECT, maxy + GATE_CONNECT)
            if clipped is not None:
                segs.append(clipped)
    return segs


def count_candidate_pixels(surface):
    n = 0
    for runs in surface.cells.values():
        for start, end, cid in runs:
            if cid in CANDIDATE_IDS:
                n += end - start
    return n


def candidate_pixels(surface, covered):
    pixels = {}
    cs = surface.cell_size
    for (cx, cy), runs in surface.cells.items():
        ox = cx * cs
        oy = cy * cs
        for start, end, cid in runs:
            if cid not in CANDIDATE_IDS:
                continue
            for s in range(start, end):
                ly, lx = divmod(s, cs)
                wx = ox + lx
                wy = oy + ly
                key = (wx, wy)
                if key not in covered:
                    pixels[key] = cid
    return pixels


def connected_components(pixel_map):
    remaining = set(pixel_map)
    for origin in sorted(remaining):
        if origin not in remaining:
            continue
        stack = [origin]
        remaining.remove(origin)
        cells = []
        while stack:
            x, y = stack.pop()
            cells.append((x, y))
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                neighbor = (x + dx, y + dy)
                if neighbor in remaining:
                    remaining.remove(neighbor)
                    stack.append(neighbor)
        yield cells


def principal_axis(cells):
    n = len(cells)
    mx = sum(p[0] for p in cells) / float(n)
    my = sum(p[1] for p in cells) / float(n)
    cxx = sum((p[0] - mx) ** 2 for p in cells) / float(n)
    cyy = sum((p[1] - my) ** 2 for p in cells) / float(n)
    cxy = sum((p[0] - mx) * (p[1] - my) for p in cells) / float(n)
    delta = math.hypot(cxx - cyy, 2.0 * cxy)
    l1 = (cxx + cyy + delta) / 2.0
    l2 = (cxx + cyy - delta) / 2.0
    if abs(cxy) > 1e-9:
        vx, vy = cxy, l1 - cxx
    elif cyy > cxx:
        vx, vy = 0.0, 1.0
    else:
        vx, vy = 1.0, 0.0
    norm = math.hypot(vx, vy) or 1.0
    return mx, my, vx / norm, vy / norm, l1, l2


def profile_component(cells):
    mx, my, vx, vy, l1, l2 = principal_axis(cells)
    bins = {}  # 沿主軸分箱，每箱只留橫向 [min, max] span
    for x, y in cells:
        t = (x - mx) * vx + (y - my) * vy
        s = (x - mx) * (-vy) + (y - my) * vx
        k = int(math.floor(t + 0.5))
        span = bins.get(k)
        if span is None:
            bins[k] = [s, s]
        elif s < span[0]:
            span[0] = s
        elif s > span[1]:
            span[1] = s
    keys = sorted(bins)
    widths = []
    polyline = []
    for k in keys:
        smin, smax = bins[k]
        widths.append(smax - smin + 1.0)
        smid = (smin + smax) / 2.0
        polyline.append((mx + k * vx + smid * (-vy), my + k * vy + smid * vx))
    length = float(keys[-1] - keys[0] + 1) if keys else 0.0
    ratio = l1 / max(l2, 1e-9)
    return {
        "polyline": polyline,
        "widths": widths,
        "length": length,
        "ratio": ratio,
        "l1": l1,
        "l2": l2,
    }


def min_dist_to_graph(px, py, segs):
    best = math.inf
    for ax, ay, bx, by in segs:
        d = dist_point_seg(px, py, ax, ay, bx, by)
        if d < best:
            best = d
    return best


def analyze_component(cells, pixel_map, surface, graph_segs, region_bounds=None):
    if len(cells) < MIN_COMPONENT_AREA:
        return None
    xs = [p[0] for p in cells]
    ys = [p[1] for p in cells]
    minx, maxx = min(xs), max(xs)
    miny, maxy = min(ys), max(ys)
    bw = maxx - minx + 1
    bh = maxy - miny + 1
    area = len(cells)
    fill = area / float(bw * bh)
    aspect = max(bw, bh) / float(max(1, min(bw, bh)))
    prof = profile_component(cells)
    polyline = prof["polyline"]
    widths = prof["widths"]
    if not polyline or not widths:
        return None
    length = prof["length"]
    median = quantile(widths, 0.5)
    p10 = quantile(widths, 0.1)
    p90 = quantile(widths, 0.9)
    surface_counts = empty_counts()
    for x, y in cells:
        surface_counts[CLASSES[pixel_map[(x, y)]]] += 1
    cand_n = 0
    for x, y in polyline:
        if surface.at(x, y) in CANDIDATE_IDS:
            cand_n += 1
    coverage = cand_n / float(len(polyline))
    d0 = min_dist_to_graph(polyline[0][0], polyline[0][1], graph_segs)
    d1 = min_dist_to_graph(polyline[-1][0], polyline[-1][1], graph_segs)
    ends = int(d0 <= GATE_CONNECT) + int(d1 <= GATE_CONNECT)
    boundary_truncated = bool(
        region_bounds is not None
        and (minx <= region_bounds[0] or miny <= region_bounds[1]
             or maxx >= region_bounds[2] or maxy >= region_bounds[3]))
    reasons = []
    if length < GATE_LENGTH:
        reasons.append("length")
    if not (GATE_WIDTH_LO <= median <= GATE_WIDTH_HI):
        reasons.append("medianWidth")
    if p90 > GATE_WIDTH_HI:
        reasons.append("widthP90")
    if (p90 - p10) > GATE_WIDTH_SPREAD:
        reasons.append("widthSpread")
    if coverage < GATE_COVERAGE:
        reasons.append("coverage")
    if min(d0, d1) > GATE_CONNECT:
        reasons.append("unconnected")
    if prof["ratio"] < 4.0 and area >= 64:
        reasons.append("noLongAxis")
    min_side = min(bw, bh)
    if (p90 > GATE_WIDTH_HI and prof["ratio"] < 6.0) or (
            fill >= 0.6 and aspect < 2.0 and min_side >= 16):
        reasons.append("field")
    if aspect < 2.5 and min_side >= 16 and fill < 0.55 and p90 > GATE_WIDTH_HI:
        reasons.append("courtyard")
    if boundary_truncated:
        reasons.append("boundaryTruncated")
    if ends == 2:
        confidence = "high"
    elif ends == 1:
        confidence = "low"
    else:
        confidence = "none"
    qpoly = [[r3(x), r3(y)] for x, y in polyline]
    comp_id = "c:%d:%d:%d:%d:%d:%d" % (
        q2(qpoly[0][0]), q2(qpoly[0][1]), q2(qpoly[-1][0]), q2(qpoly[-1][1]),
        len(qpoly), area)
    return {
        "id": comp_id,
        "polyline": qpoly,
        "length": r3(length),
        "widthMedian": r3(median),
        "widthP10": r3(p10),
        "widthP90": r3(p90),
        "coverage": r3(coverage),
        "area": area,
        "bbox": {"x0": minx, "y0": miny, "x1": maxx, "y1": maxy},
        "surfaceCounts": surface_counts,
        "connection": {
            "d0": r3(1e9 if math.isinf(d0) else d0),
            "d1": r3(1e9 if math.isinf(d1) else d1),
            "endsWithin8": ends,
        },
        "confidence": confidence,
        "boundaryTruncated": boundary_truncated,
        "accepted": not reasons,
        "rejectionReasons": reasons,
    }


def build_report(streets, surfaces_loaded, surface, xml_sha, surface_sha,
                 max_candidate_pixels=DEFAULT_MAX_CANDIDATE_PIXELS):
    max_candidate_pixels = require_int(
        max_candidate_pixels, "max_candidate_pixels")
    if max_candidate_pixels < 0:
        raise AuditError("max_candidate_pixels 必須 >= 0")
    surface_source = surfaces_loaded["source"]
    scope = surface_source["scope"]
    cell_bounds = scope["bounds"]
    surface_bounds = (
        cell_bounds[0] * CELL_SIZE,
        cell_bounds[1] * CELL_SIZE,
        (cell_bounds[2] + 1) * CELL_SIZE - 1,
        (cell_bounds[3] + 1) * CELL_SIZE - 1,
    )
    coverage_status = "partial" if scope["mode"] == "region" else "full"
    widths = [st["width"] for st in streets]
    point_count = sum(len(st["pts"]) for st in streets)
    empty_n = sum(1 for st in streets if not str(st["name"]).strip())
    short_n = sum(1 for st in streets if len(st["pts"]) < 2)
    zero_n = 0
    railroad_n = 0
    for st in streets:
        pts = st["pts"]
        if len(pts) >= 2 and is_railroad(st["name"], pts[0][0], pts[0][1]):
            railroad_n += 1
        for k in range(len(pts) - 1):
            a, b = pts[k], pts[k + 1]
            if math.hypot(b[0] - a[0], b[1] - a[1]) <= 1e-4:
                zero_n += 1
    findings = topology_findings(streets)
    dup_n = sum(1 for finding in findings if finding["kind"] == "duplicate")
    comp_count, comp_sizes = raw_exact_vertex_components(streets)

    samples = []
    total_probe_count = 0
    missing_probe_count = 0
    for i, st in enumerate(streets):
        pts = st["pts"]
        if len(pts) < 2:
            continue
        sid = street_sig(pts)
        rail = is_railroad(st["name"], pts[0][0], pts[0][1])
        for k in range(len(pts) - 1):
            x0, y0 = pts[k]
            x1, y1 = pts[k + 1]
            sampled = sample_segment(surface, x0, y0, x1, y1, st["width"])
            total_probe_count += sampled["sampleCount"]
            missing_probe_count += sampled["missingCount"]
            samples.append({
                "id": "%s:%d" % (sid, k),
                "streetIndex": i,
                "segIndex": k,
                "x0": r3(x0),
                "y0": r3(y0),
                "x1": r3(x1),
                "y1": r3(y1),
                "xmlWidth": st["width"],
                "length": r3(sampled["length"]),
                "railroad": rail,
                "surface": {
                    "sampleCount": sampled["sampleCount"],
                    "missingCount": sampled["missingCount"],
                    "counts": sampled["counts"],
                    "ratios": ratios_from_counts(sampled["counts"]),
                    "centerCounts": sampled["centerCounts"],
                    "leftCounts": sampled["leftCounts"],
                    "rightCounts": sampled["rightCounts"],
                },
            })

    # Logical pixel cap must run before coverage painting or raster expansion.
    pixel_count = count_candidate_pixels(surface)
    if pixel_count > max_candidate_pixels:
        candidate_analysis = {
            "status": "skipped",
            "reason": "candidatePixelLimit",
            "pixelCount": pixel_count,
            "limit": max_candidate_pixels,
        }
        candidates = []
    else:
        candidate_analysis = {
            "status": "partial" if scope["mode"] == "region" else "ok",
            "pixelCount": pixel_count,
            "limit": max_candidate_pixels,
        }
        covered = paint_coverage(streets, surface_bounds)
        pixels = candidate_pixels(surface, covered)
        graph_segs = graph_segments(streets, surface_bounds)
        region_bounds = surface_bounds if scope["mode"] == "region" else None
        candidates = []
        for cells in connected_components(pixels):
            item = analyze_component(
                cells, pixels, surface, graph_segs,
                region_bounds=region_bounds)
            if item is not None:
                candidates.append(item)
        candidates.sort(key=lambda c: (c["id"], c["bbox"]["y0"], c["bbox"]["x0"]))

    return {
        "schemaVersion": SCHEMA_VERSION,
        "source": {
            "xmlSha256": xml_sha,
            "surfaceFingerprint": surface_sha,
            "surfaceSource": surface_source,
        },
        "surfaceCoverage": {
            "status": coverage_status,
            "providedCellCount": len(surface.cells),
            "bounds": list(cell_bounds),
            "totalProbeCount": total_probe_count,
            "missingProbeCount": missing_probe_count,
        },
        "baseline": {
            "streetCount": len(streets),
            "pointCount": point_count,
            "widthMin": min(widths) if widths else 0,
            "widthMax": max(widths) if widths else 0,
            "widthMedian": r3(quantile(widths, 0.5)) if widths else 0.0,
            "emptyNameCount": empty_n,
            "shortCount": short_n,
            "zeroLengthCount": zero_n,
            "duplicateCount": dup_n,
            "railroadCount": railroad_n,
        },
        "topology": {
            "findings": findings,
            "rawExactVertexComponentCount": comp_count,
            "rawExactVertexComponentSizes": comp_sizes,
        },
        "streetSamples": samples,
        "candidateAnalysis": candidate_analysis,
        "candidates": candidates,
    }


def audit(streets_path, surfaces_path, max_candidate_pixels=DEFAULT_MAX_CANDIDATE_PIXELS):
    streets_data = Path(streets_path).read_bytes()
    surfaces_data = Path(surfaces_path).read_bytes()
    xml_sha = hashlib.sha256(streets_data).hexdigest()
    surface_sha = hashlib.sha256(surfaces_data).hexdigest()
    streets = parse_streets(streets_data)
    loaded = load_surfaces(surfaces_data)
    surface = SurfaceIndex(loaded)
    return build_report(streets, loaded, surface, xml_sha, surface_sha,
                        max_candidate_pixels=max_candidate_pixels)


def _paths_alias(first, second):
    first_path = Path(first)
    second_path = Path(second)
    first_key = os.path.normcase(str(first_path.resolve(strict=False)))
    second_key = os.path.normcase(str(second_path.resolve(strict=False)))
    if first_key == second_key:
        return True
    if first_path.exists() and second_path.exists():
        try:
            return os.path.samefile(first_path, second_path)
        except OSError:
            pass
    return False


def reject_path_aliases(streets, surfaces, out, preview=None):
    paths = [("streets", streets), ("surfaces", surfaces), ("out", out)]
    if preview is not None:
        paths.append(("preview", preview))
    for i, (first_label, first) in enumerate(paths):
        for second_label, second in paths[i + 1:]:
            if _paths_alias(first, second):
                raise AuditError("path alias：%s 與 %s 指向同一路徑" % (
                    first_label, second_label))


def atomic_write_bytes(path, data):
    target = Path(path)
    fd, temp_name = tempfile.mkstemp(
        prefix=".%s." % target.name, suffix=".tmp", dir=str(target.parent))
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.replace(temp_path, target)
    finally:
        if temp_path.exists():
            temp_path.unlink()


def write_canonical_file(obj, path):
    atomic_write_bytes(path, dumps_canonical(obj).encode("utf-8"))


def write_preview(report, path):
    features = []
    for cand in report.get("candidates", []):
        coords = cand.get("polyline") or []
        if len(coords) >= 2:
            geom = {"type": "LineString", "coordinates": coords}
        elif len(coords) == 1:
            geom = {"type": "Point", "coordinates": coords[0]}
        else:
            continue
        features.append({
            "type": "Feature",
            "properties": {
                "id": cand["id"],
                "kind": "candidate",
                "accepted": cand["accepted"],
                "confidence": cand["confidence"],
                "boundaryTruncated": cand["boundaryTruncated"],
                "length": cand["length"],
                "widthMedian": cand["widthMedian"],
                "rejectionReasons": list(cand["rejectionReasons"]),
            },
            "geometry": geom,
        })
    doc = {"type": "FeatureCollection", "features": features}
    atomic_write_bytes(path, dumps_canonical(doc).encode("utf-8"))


def main(argv=None):
    parser = argparse.ArgumentParser(
        prog="audit_streets.py",
        description="稽核 streets.xml 與 road-surfaces-v1.json，寫出 road-audit-v1.json")
    parser.add_argument("--streets", required=True, help="官方或 fixture streets.xml")
    parser.add_argument("--surfaces", required=True, help="MapRendering road-surfaces-v1.json")
    parser.add_argument("--out", required=True, help="canonical road-audit-v1.json")
    parser.add_argument("--preview", default=None, help="可選 GeoJSON preview（非 patch 輸入）")
    parser.add_argument(
        "--max-candidate-pixels", type=int, default=DEFAULT_MAX_CANDIDATE_PIXELS,
        help="缺路 raster 展開上限（先計數；超限跳過 candidates，預設 2000000）")
    args = parser.parse_args(argv)
    try:
        reject_path_aliases(args.streets, args.surfaces, args.out, args.preview)
        report = audit(args.streets, args.surfaces,
                       max_candidate_pixels=args.max_candidate_pixels)
        write_canonical_file(report, args.out)
        if args.preview:
            write_preview(report, args.preview)
    except (AuditError, OSError) as exc:
        sys.stderr.write("%s\n" % exc)
        return 2
    analysis = report["candidateAnalysis"]
    coverage = report["surfaceCoverage"]
    if analysis["status"] == "skipped":
        advice = ("; re-run with a region surface JSON"
                  if coverage["status"] == "full" else "")
        sys.stderr.write(
            "candidate analysis skipped: pixelCount=%d exceeds "
            "--max-candidate-pixels=%d%s\n" % (
                analysis["pixelCount"], analysis["limit"], advice))
    accepted = sum(1 for candidate in report["candidates"] if candidate["accepted"])
    sys.stdout.write(
        "wrote %s (streets=%d points=%d candidates=%d accepted=%d "
        "candidateAnalysis=%s surfaceCoverage=%s)\n" % (
            args.out,
            report["baseline"]["streetCount"],
            report["baseline"]["pointCount"],
            len(report["candidates"]),
            accepted,
            analysis["status"],
            coverage["status"],
        ))
    return 0


if __name__ == "__main__":
    sys.exit(main())
