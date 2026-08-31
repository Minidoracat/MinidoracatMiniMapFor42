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
全圖 candidate 以 row/span streaming 分析；--max-candidate-pixels 同時限制單一
元件與全域 active detailed spans 像素量，超限元件仍以 aggregate evidence 拒絕。
"""
from __future__ import annotations

import argparse
import bisect
import collections
import hashlib
import itertools
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
CLASSES = ("unknown", "paved", "gravel", "dirt-candidate", "natural", "dirt-edge")
CLASS_ID = {name: i for i, name in enumerate(CLASSES)}
# dirt-edge（blends_natural_01_{64..71}，dirt→grass 過渡邊）：窄土徑的線性
# 訊號——路面本體與曠野裸泥同 tile 無法區分，但窄路帶每格貼草緣連成 edge 帶。
# edge 必須「獨輪」收集：與 dirt-candidate 同輪連通會把 edge 帶融進曠野大面
# component 一起被 gate 拒（v2 首跑實證：加入同一集合後候選數零變化）。
# 農田犁溝同類橫紋彼此連通成面，靠 width/area gate 拒（與 gravel 農地同機制）。
PRIMARY_CANDIDATE_IDS = frozenset(
    {CLASS_ID["paved"], CLASS_ID["gravel"], CLASS_ID["dirt-candidate"]})
EDGE_CANDIDATE_IDS = frozenset({CLASS_ID["dirt-edge"]})
# 全集：pixel 統計與候選 coverage（土徑候選的路徑點常落在路心 dirt-candidate）
CANDIDATE_IDS = PRIMARY_CANDIDATE_IDS | EDGE_CANDIDATE_IDS
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
MAX_CANDIDATE_PIXELS = 2000000
DEFAULT_MAX_CANDIDATE_PIXELS = MAX_CANDIDATE_PIXELS
MAX_COMPONENTS = 500000  # edge 獨輪的碎片 component 全圖 5-40 萬（recon 實證）
MAX_REPORTED_CANDIDATES = 10000
MAX_CANDIDATE_GRAPH_WORK = 100000000
MAX_CANDIDATE_POLYLINE_POINTS = 8192
MAX_TOTAL_PROFILE_WORK = 100000000
MAX_TOTAL_CANDIDATE_POLYLINE_POINTS = 2000000
MAX_CANDIDATE_GRAPH_BUCKET_REFS = 250000
MAX_STREETS = 65536
MAX_SURFACE_CELLS = 65536
MIN_CELL_COORD = -128
MAX_CELL_COORD = 127
MAX_SOURCE_INPUTS = 1024
MAX_SOURCE_CELL_ROWS = 65536
MAX_POINTS_PER_STREET = 4096
MAX_TOTAL_SEGMENTS = 16384
MAX_TOTAL_PROBES = 8000000
MAX_SEGMENT_LENGTH = 16384
MIN_STREET_WIDTH = 1
TOPOLOGY_BUCKET_SIZE = 64
MAX_BUCKET_REFERENCES = 250000
MAX_TOPOLOGY_PAIR_WORK = 250000
MAX_ENDPOINT_WORK = 10000000
MAX_TOPOLOGY_PAIR_SCAN = 1000000
MAX_TOPOLOGY_FINDINGS = 20000
MAX_STREET_WIDTH = 64
MIN_POINT_COORD = -32768.0
MAX_POINT_COORD = 32767.5
NEAR_ENDPOINT_LO = 0.75
MAX_STREETS_XML_BYTES = 8 * 1024 * 1024
MAX_SURFACES_JSON_BYTES = 64 * 1024 * 1024
MAX_TEXT_CHARS = 1024
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


def _validate_candidate_pixel_limit(value):
    value = require_int(value, "max_candidate_pixels")
    if not 0 <= value <= MAX_CANDIDATE_PIXELS:
        raise AuditError("max_candidate_pixels 必須介於 0..%d" % (
            MAX_CANDIDATE_PIXELS,))
    return value


def _require_text_limit(value, label):
    if len(value) > MAX_TEXT_CHARS:
        raise AuditError("%s 不得超過 %d chars" % (
            label, MAX_TEXT_CHARS))


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
    total_segments = 0
    total_probes = 0
    children = list(root)
    if len(children) > MAX_STREETS:
        raise AuditError("streets 最多 %d 個 street，得到 %d" % (
            MAX_STREETS, len(children)))
    for street_index, child in enumerate(children):
        name = localname(child.tag)
        if name != "street":
            raise AuditError('unrecognised element "%s"' % name)
        unknown_attrs = sorted(set(child.attrib) - {"name", "width"})
        if unknown_attrs:
            raise AuditError("street[%d] 未知 attributes：%r" % (
                street_index, unknown_attrs))
        street_name = child.get("name", "")
        _require_text_limit(street_name, "street[%d].name" % street_index)
        width = _xml_int(child, "width", "street[%d]" % street_index)
        if not MIN_STREET_WIDTH <= width <= MAX_STREET_WIDTH:
            raise AuditError("street[%d].width 必須介於 %d..%d，得到 %d" % (
                street_index, MIN_STREET_WIDTH, MAX_STREET_WIDTH, width))
        containers = list(child)
        if len(containers) != 1 or localname(containers[0].tag) != "points":
            tags = [localname(item.tag) for item in containers]
            raise AuditError("street[%d] 必須恰有一個 points，得到 %r" % (
                street_index, tags))
        points = containers[0]
        if points.attrib:
            raise AuditError("street[%d].points 不接受 attributes" % street_index)
        pts = []
        point_nodes = list(points)
        if len(point_nodes) > MAX_POINTS_PER_STREET:
            raise AuditError("street[%d].points 最多 %d，得到 %d" % (
                street_index, MAX_POINTS_PER_STREET, len(point_nodes)))
        for point_index, point in enumerate(point_nodes):
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
            coord = (_xml_float(point, "x", label),
                     _xml_float(point, "y", label))
            for axis, value in zip(("x", "y"), coord):
                if not MIN_POINT_COORD <= value <= MAX_POINT_COORD:
                    raise AuditError(
                        "street[%d].point[%d].%s 必須介於 -32768..32767.5" % (
                            street_index, point_index, axis))
            if pts:
                segment_length = math.hypot(
                    coord[0] - pts[-1][0], coord[1] - pts[-1][1])
                if segment_length > MAX_SEGMENT_LENGTH:
                    raise AuditError(
                        "street[%d].segment[%d] 長度不得超過 %d" % (
                            street_index, point_index - 1,
                            MAX_SEGMENT_LENGTH))
                if segment_length <= 1e-9:
                    total_probes += 1
                else:
                    total_probes += 3 * (
                        max(1, int(round(segment_length))) + 1)
                if total_probes > MAX_TOTAL_PROBES:
                    raise AuditError(
                        "streets total probes 最多 %d，得到 %d" % (
                            MAX_TOTAL_PROBES, total_probes))
            pts.append(coord)
        total_segments += max(0, len(pts) - 1)
        if total_segments > MAX_TOTAL_SEGMENTS:
            raise AuditError("streets total segments 最多 %d，得到 %d" % (
                MAX_TOTAL_SEGMENTS, total_segments))
        streets.append({
            "name": street_name,
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


def _require_cell_domain(value, label):
    if not MIN_CELL_COORD <= value <= MAX_CELL_COORD:
        raise AuditError("%s 必須介於 %d..%d" % (
            label, MIN_CELL_COORD, MAX_CELL_COORD))


def _validate_surface_source(source, cell_keys):
    require_keys(source, {"pzBuild", "scope", "inputs"}, "source")
    pz_build = source["pzBuild"]
    if not isinstance(pz_build, str) or not pz_build.strip():
        raise AuditError("source.pzBuild 必須為非空字串")
    _require_text_limit(pz_build, "source.pzBuild")

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
        for index, value in enumerate(requested):
            _require_cell_domain(
                value, "source.scope.requestedRegion[%d]" % index)
        if requested[0] > requested[2] or requested[1] > requested[3]:
            raise AuditError("source.scope.requestedRegion bounds 顛倒")
    selected_count = require_int(
        scope["selectedCellCount"], "source.scope.selectedCellCount")
    if selected_count != len(cell_keys):
        raise AuditError("source.scope.selectedCellCount=%d 與 cells=%d 不一致" % (
            selected_count, len(cell_keys)))
    bounds = require_int_list(scope["bounds"], 4, "source.scope.bounds")
    for index, value in enumerate(bounds):
        _require_cell_domain(value, "source.scope.bounds[%d]" % index)
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
    if len(inputs) > MAX_SOURCE_INPUTS:
        raise AuditError("source.inputs 最多 %d，得到 %d" % (
            MAX_SOURCE_INPUTS, len(inputs)))
    source_cell_row_count = 0
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
        if isinstance(layer, str):
            _require_text_limit(
                layer, "source.inputs[%d].layer" % input_index)
        if (not isinstance(layer, str) or not layer.strip()
                or layer != layer.strip() or layer in (".", "..")
                or "/" in layer or "\\" in layer or "\x00" in layer):
            raise AuditError("source.inputs[%d].layer 必須為 map-dir basename" % input_index)
        rows = item["cells"]
        if not isinstance(rows, list) or not rows:
            raise AuditError("source.inputs[%d].cells 必須為非空 array" % input_index)
        source_cell_row_count += len(rows)
        if source_cell_row_count > MAX_SOURCE_CELL_ROWS:
            raise AuditError("source.inputs cell rows 最多 %d，得到 %d" % (
                MAX_SOURCE_CELL_ROWS, source_cell_row_count))
        last_coord = None
        for row_index, row in enumerate(rows):
            label = "source.inputs[%d].cells[%d]" % (input_index, row_index)
            if not isinstance(row, list) or len(row) != 4:
                raise AuditError("%s 必須為 [cx,cy,lotheader,lotpack]" % label)
            cx = require_int(row[0], label + "[0]")
            cy = require_int(row[1], label + "[1]")
            _require_cell_domain(cx, label + "[0]")
            _require_cell_domain(cy, label + "[1]")
            coord = (cy, cx)
            if last_coord is not None and coord <= last_coord:
                raise AuditError("source.inputs[%d].cells 必須依 y,x 排序且不得重複" %
                                 input_index)
            last_coord = coord
            for field_index in (2, 3):
                if not isinstance(row[field_index], str):
                    raise AuditError("%s[%d] 必須為字串" % (
                        label, field_index))
                _require_text_limit(
                    row[field_index], "%s[%d]" % (label, field_index))
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
    _require_text_limit(map_id, "mapId")
    cell_size = require_int(raw["cellSize"], "cellSize")
    if cell_size != CELL_SIZE:
        raise AuditError("cellSize 必須為 %d，得到 %r" % (CELL_SIZE, cell_size))
    classes = raw["classes"]
    if classes != list(CLASSES):
        raise AuditError("錯 class table：%r（需要 %r）" % (classes, list(CLASSES)))
    cells = raw["cells"]
    if not isinstance(cells, list) or not cells:
        raise AuditError("cells 必須為非空 array")
    if len(cells) > MAX_SURFACE_CELLS:
        raise AuditError("cells 最多 %d，得到 %d" % (
            MAX_SURFACE_CELLS, len(cells)))
    index = {}
    last_coord = None
    for i, cell in enumerate(cells):
        require_keys(cell, {"x", "y", "runs"}, "cells[%d]" % i)
        cx = require_int(cell["x"], "cell.x")
        cy = require_int(cell["y"], "cell.y")
        _require_cell_domain(cx, "cell.x")
        _require_cell_domain(cy, "cell.y")
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
        i = bisect.bisect_right(runs, start, key=lambda run: run[1])
        if i < len(runs):
            a, b, cid = runs[i]
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


def _segment_bucket_keys(a, b):
    """線段穿越的 64m supercover buckets；邊界/角點同時納入兩側。"""
    size = float(TOPOLOGY_BUCKET_SIZE)
    x = int(math.floor(a[0] / size))
    y = int(math.floor(a[1] / size))
    end_x = int(math.floor(b[0] / size))
    end_y = int(math.floor(b[1] / size))
    keys = {(x, y)}
    dx = b[0] - a[0]
    dy = b[1] - a[1]
    epsilon = 1e-12

    if abs(dx) <= epsilon:
        step_x = 0
        t_max_x = math.inf
        t_delta_x = math.inf
    else:
        step_x = 1 if dx > 0.0 else -1
        boundary_x = (x + (1 if step_x > 0 else 0)) * size
        t_max_x = (boundary_x - a[0]) / dx
        t_delta_x = size / abs(dx)
    if abs(dy) <= epsilon:
        step_y = 0
        t_max_y = math.inf
        t_delta_y = math.inf
    else:
        step_y = 1 if dy > 0.0 else -1
        boundary_y = (y + (1 if step_y > 0 else 0)) * size
        t_max_y = (boundary_y - a[1]) / dy
        t_delta_y = size / abs(dy)

    while x != end_x or y != end_y:
        if t_max_x < t_max_y - epsilon:
            x += step_x
            t_max_x += t_delta_x
        elif t_max_y < t_max_x - epsilon:
            y += step_y
            t_max_y += t_delta_y
        else:
            next_x = x + step_x
            next_y = y + step_y
            if step_x:
                keys.add((next_x, y))
                t_max_x += t_delta_x
            if step_y:
                keys.add((x, next_y))
                t_max_y += t_delta_y
            x, y = next_x, next_y
        keys.add((x, y))

    if (abs(dx) <= epsilon
            and math.isclose(a[0] / size, round(a[0] / size),
                             abs_tol=epsilon)):
        keys.update((bucket_x - 1, bucket_y)
                    for bucket_x, bucket_y in tuple(keys))
    if (abs(dy) <= epsilon
            and math.isclose(a[1] / size, round(a[1] / size),
                             abs_tol=epsilon)):
        keys.update((bucket_x, bucket_y - 1)
                    for bucket_x, bucket_y in tuple(keys))
    return sorted(keys)


def topology_findings(streets, work=None):
    findings = []
    sig_first = {}
    segs = []
    if work is None:
        work = {}
    work.update({
        "bucketReferenceCount": 0,
        "topologyPairWorkCount": 0,
        "topologyPairScanCount": 0,
        "endpointWorkCount": 0,
    })

    def add_finding(finding):
        next_count = len(findings) + 1
        if next_count > MAX_TOPOLOGY_FINDINGS:
            raise AuditError("topology findings 最多 %d，得到 %d" % (
                MAX_TOPOLOGY_FINDINGS, next_count))
        findings.append(finding)
    for i, st in enumerate(streets):
        pts = st["pts"]
        sid = street_sig(pts)
        if not str(st["name"]).strip():
            add_finding({
                "kind": "emptyName",
                "id": sid,
                "streetIndex": i,
            })
        if len(pts) < 2:
            add_finding({
                "kind": "short",
                "id": sid,
                "streetIndex": i,
                "pointCount": len(pts),
            })
            continue
        if sid in sig_first:
            add_finding({
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
                add_finding({
                    "kind": "zeroLength",
                    "id": sid,
                    "streetIndex": i,
                    "segIndex": k,
                })
            segs.append((i, k, a, b, sid))
        for a in range(len(pts) - 1):
            for b in range(a + 2, len(pts) - 1):
                work["topologyPairWorkCount"] += 1
                if work["topologyPairWorkCount"] > MAX_TOPOLOGY_PAIR_WORK:
                    raise AuditError(
                        "topology pair work 最多 %d，得到 %d" % (
                            MAX_TOPOLOGY_PAIR_WORK,
                            work["topologyPairWorkCount"]))
                if proper_intersect(pts[a], pts[a + 1], pts[b], pts[b + 1]):
                    add_finding({
                        "kind": "selfIntersection",
                        "id": sid,
                        "streetIndex": i,
                        "segA": a,
                        "segB": b,
                    })

    segment_buckets = {}
    for segment_index, (_, _, a0, a1, _) in enumerate(segs):
        for key in _segment_bucket_keys(a0, a1):
            work["bucketReferenceCount"] += 1
            if work["bucketReferenceCount"] > MAX_BUCKET_REFERENCES:
                raise AuditError(
                    "topology bucket references 最多 %d，得到 %d" % (
                        MAX_BUCKET_REFERENCES,
                        work["bucketReferenceCount"]))
            segment_buckets.setdefault(key, []).append(segment_index)

    seen_pairs = set()
    for key in sorted(segment_buckets):
        bucket = segment_buckets[key]
        for first_pos, first in enumerate(bucket):
            ia, ka, a0, a1, sa = segs[first]
            for second in bucket[first_pos + 1:]:
                work["topologyPairScanCount"] += 1
                if work["topologyPairScanCount"] > MAX_TOPOLOGY_PAIR_SCAN:
                    raise AuditError(
                        "topology pair scan 最多 %d，得到 %d" % (
                            MAX_TOPOLOGY_PAIR_SCAN,
                            work["topologyPairScanCount"]))
                ib, kb, b0, b1, sb = segs[second]
                if ia == ib:
                    continue
                pair_key = (
                    min(first, second) * MAX_TOTAL_SEGMENTS
                    + max(first, second))
                if pair_key in seen_pairs:
                    continue
                work["topologyPairWorkCount"] += 1
                if work["topologyPairWorkCount"] > MAX_TOPOLOGY_PAIR_WORK:
                    raise AuditError(
                        "topology pair work 最多 %d，得到 %d" % (
                            MAX_TOPOLOGY_PAIR_WORK,
                            work["topologyPairWorkCount"]))
                seen_pairs.add(pair_key)
                if proper_intersect(a0, a1, b0, b1):
                    add_finding({
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
            bucket_x = int(math.floor(px / TOPOLOGY_BUCKET_SIZE))
            bucket_y = int(math.floor(py / TOPOLOGY_BUCKET_SIZE))
            nearby = set()
            for near_y in range(bucket_y - 1, bucket_y + 2):
                for near_x in range(bucket_x - 1, bucket_x + 2):
                    nearby.update(segment_buckets.get((near_x, near_y), ()))
            for segment_index in sorted(nearby):
                work["endpointWorkCount"] += 1
                if work["endpointWorkCount"] > MAX_ENDPOINT_WORK:
                    raise AuditError(
                        "topology endpoint work 最多 %d，得到 %d" % (
                            MAX_ENDPOINT_WORK, work["endpointWorkCount"]))
                j, _, b0, b1, osig = segs[segment_index]
                if i == j:
                    continue
                d = dist_point_seg(px, py, b0[0], b0[1], b1[0], b1[1])
                if best is None or d < best[0]:
                    best = (d, j, osig)
            if best is not None and NEAR_ENDPOINT_LO <= best[0] <= GATE_CONNECT:
                add_finding({
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
        f.get("segB", 0),
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


def _capsule_row_span(ax, ay, bx, by, py, radius):
    """回傳 capsule 與水平線 py 的連續 x span；None 表示不相交。"""
    intervals = []
    radius2 = radius * radius
    for ex, ey in ((ax, ay), (bx, by)):
        dy0 = py - ey
        if dy0 * dy0 <= radius2:
            half = math.sqrt(max(0.0, radius2 - dy0 * dy0))
            intervals.append((ex - half, ex + half))

    dx = bx - ax
    dy = by - ay
    length2 = dx * dx + dy * dy
    if length2 > 1e-18:
        yoff = py - ay
        lo = -math.inf
        hi = math.inf

        if abs(dx) <= 1e-18:
            dot = dy * yoff
            if not (-1e-9 <= dot <= length2 + 1e-9):
                lo, hi = 1.0, 0.0
        else:
            p0 = ax - dy * yoff / dx
            p1 = ax + (length2 - dy * yoff) / dx
            lo = max(lo, min(p0, p1))
            hi = min(hi, max(p0, p1))

        reach = radius * math.sqrt(length2)
        if abs(dy) <= 1e-18:
            if abs(dx * yoff) > reach + 1e-9:
                lo, hi = 1.0, 0.0
        else:
            center = ax + dx * yoff / dy
            half = reach / abs(dy)
            lo = max(lo, center - half)
            hi = min(hi, center + half)
        if lo <= hi:
            intervals.append((lo, hi))

    if not intervals:
        return None
    lo = min(item[0] for item in intervals)
    hi = max(item[1] for item in intervals)
    start = int(math.ceil(lo - 0.5 - 1e-9))
    end = int(math.floor(hi - 0.5 + 1e-9)) + 1
    return (start, end) if start < end else None


def _merge_intervals(intervals):
    merged = []
    for start, end in sorted(intervals):
        if not merged or start > merged[-1][1]:
            merged.append([start, end])
        elif end > merged[-1][1]:
            merged[-1][1] = end
    return [tuple(item) for item in merged]


def paint_coverage(streets, bounds):
    """把既有 streets coverage rasterize 成每列合併 spans，不建逐像素 set。"""
    rows = {}
    minx, miny, maxx, maxy = bounds
    for st in streets:
        pts = st["pts"]
        if len(pts) < 2 or is_railroad(st["name"], pts[0][0], pts[0][1]):
            continue
        radius = math.sqrt((float(st["width"]) / 2.0) ** 2 + 0.05)
        for i in range(len(pts) - 1):
            clipped = clip_segment_to_rect(
                pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1],
                minx - radius - 1.0, miny - radius - 1.0,
                maxx + radius + 1.0, maxy + radius + 1.0)
            if clipped is None:
                continue
            x0, y0, x1, y1 = clipped
            row0 = max(miny, int(math.ceil(min(y0, y1) - radius - 0.5 - 1e-9)))
            row1 = min(maxy, int(math.floor(max(y0, y1) + radius - 0.5 + 1e-9)))
            for sy in range(row0, row1 + 1):
                span = _capsule_row_span(x0, y0, x1, y1, sy + 0.5, radius)
                if span is None:
                    continue
                start = max(minx, span[0])
                end = min(maxx + 1, span[1])
                if start < end:
                    rows.setdefault(sy, []).append((start, end))
    return {y: _merge_intervals(rows[y]) for y in sorted(rows)}


def graph_segments(streets, bounds):
    """建立 nonrail streetSample segments 與 <=8 格 alignment spatial buckets。"""
    minx, miny, maxx, maxy = bounds
    segments = []
    bucket_size = 64
    buckets = {}
    bucket_reference_count = 0
    for street_index, st in enumerate(streets):
        pts = st["pts"]
        if len(pts) < 2 or is_railroad(st["name"], pts[0][0], pts[0][1]):
            continue
        for k in range(len(pts) - 1):
            coords = (
                pts[k][0], pts[k][1], pts[k + 1][0], pts[k + 1][1])
            segment = {
                "id": "s:%d:%d" % (street_index, k),
                "coords": coords,
            }
            segment_index = len(segments)
            segments.append(segment)
            clipped = clip_segment_to_rect(
                coords[0], coords[1], coords[2], coords[3],
                minx - GATE_CONNECT, miny - GATE_CONNECT,
                maxx + GATE_CONNECT, maxy + GATE_CONNECT)
            if clipped is None:
                continue
            ax, ay, bx, by = clipped
            expanded_keys = set()
            for bucket_x, bucket_y in _segment_bucket_keys(
                    (ax, ay), (bx, by)):
                for near_y in range(bucket_y - 1, bucket_y + 2):
                    for near_x in range(bucket_x - 1, bucket_x + 2):
                        expanded_keys.add((near_x, near_y))
            for key in sorted(expanded_keys):
                next_count = bucket_reference_count + 1
                if next_count > MAX_CANDIDATE_GRAPH_BUCKET_REFS:
                    raise AuditError(
                        "candidate graph bucket references 最多 %d，得到 %d" % (
                            MAX_CANDIDATE_GRAPH_BUCKET_REFS, next_count))
                bucket_reference_count = next_count
                buckets.setdefault(key, []).append(segment_index)
    return {
        "segments": segments,
        "buckets": buckets,
        "bucketSize": bucket_size,
        "bucketReferenceCount": bucket_reference_count,
    }


def count_candidate_pixels(surface):
    return sum(
        end - start
        for runs in surface.cells.values()
        for start, end, cid in runs
        if cid in CANDIDATE_IDS)


def _append_candidate_span(spans, start, end, cid):
    if start >= end:
        return
    last = spans[-1] if spans else None
    if last is not None and last[1] == start and last[2] == cid:
        spans[-1] = (last[0], end, cid)
    else:
        spans.append((start, end, cid))


def _subtract_coverage(spans, covered):
    if not covered:
        return spans
    out = []
    cover_index = 0
    for start, end, cid in spans:
        while cover_index < len(covered) and covered[cover_index][1] <= start:
            cover_index += 1
        cursor = start
        index = cover_index
        while index < len(covered) and covered[index][0] < end:
            cover_start, cover_end = covered[index]
            if cursor < cover_start:
                _append_candidate_span(out, cursor, min(end, cover_start), cid)
            cursor = max(cursor, cover_end)
            if cursor >= end:
                break
            index += 1
        if cursor < end:
            _append_candidate_span(out, cursor, end, cid)
    return out


def candidate_rows(surface, covered, work, candidate_ids):
    """依 world y 產生 uncovered candidate spans；同列跨 cell 自然相接。"""
    cs = surface.cell_size
    items = sorted(
        surface.cells.items(),
        key=lambda item: (item[0][1], item[0][0]))
    for cy, group in itertools.groupby(items, key=lambda item: item[0][1]):
        rows = [[] for _ in range(cs)]
        for (cx, _), runs in group:
            ox = cx * cs
            for start, end, cid in runs:
                if cid not in candidate_ids:
                    continue
                pos = start
                while pos < end:
                    ly = pos // cs
                    row_end = min(end, (ly + 1) * cs)
                    _append_candidate_span(
                        rows[ly],
                        ox + pos - ly * cs,
                        ox + row_end - ly * cs,
                        cid)
                    pos = row_end
        for ly, spans in enumerate(rows):
            wy = cy * cs + ly
            uncovered = _subtract_coverage(spans, covered.get(wy, ()))
            work["uncoveredPixelCount"] += sum(
                end - start for start, end, _ in uncovered)
            work["rowSpanCount"] += len(uncovered)
            yield wy, uncovered


def _sum_prefix(n):
    return n * (n - 1) // 2


def _sum_squares_prefix(n):
    return n * (n - 1) * (2 * n - 1) // 6


class _SpanComponent:
    __slots__ = (
        "parent", "serial", "area", "minx", "miny", "maxx", "maxy",
        "sumx", "sumy", "sumx2", "sumy2", "sumxy",
        "surface_counts", "spans", "retained_pixels",
        "storage_limited", "storage_limit_kind")

    def __init__(self, serial):
        self.parent = self
        self.serial = serial
        self.area = 0
        self.minx = None
        self.miny = None
        self.maxx = None
        self.maxy = None
        self.sumx = 0
        self.sumy = 0
        self.sumx2 = 0
        self.sumy2 = 0
        self.sumxy = 0
        self.surface_counts = [0] * len(CLASSES)
        self.spans = []
        self.retained_pixels = 0
        self.storage_limited = False
        self.storage_limit_kind = None

    def drop_detail(self, work, kind):
        if self.spans is not None:
            work["currentRetainedDetailedPixelCount"] -= self.retained_pixels
            work["currentRetainedDetailedSpanCount"] -= len(self.spans)
            self.spans = None
            self.retained_pixels = 0
        self.storage_limited = True
        if self.storage_limit_kind != "global":
            self.storage_limit_kind = kind

    def add_span(self, y, start, end, cid, limit, work):
        count = end - start
        sumx = _sum_prefix(end) - _sum_prefix(start)
        self.area += count
        self.minx = start if self.minx is None else min(self.minx, start)
        self.maxx = end - 1 if self.maxx is None else max(self.maxx, end - 1)
        self.miny = y if self.miny is None else min(self.miny, y)
        self.maxy = y if self.maxy is None else max(self.maxy, y)
        self.sumx += sumx
        self.sumy += y * count
        self.sumx2 += _sum_squares_prefix(end) - _sum_squares_prefix(start)
        self.sumy2 += y * y * count
        self.sumxy += y * sumx
        self.surface_counts[cid] += count
        if self.spans is None:
            return
        if self.area > limit:
            self.drop_detail(work, "component")
            return
        if (work["currentRetainedDetailedPixelCount"] + count
                > work["globalRetentionBudgetPixels"]):
            self.drop_detail(work, "global")
            return
        self.spans.append((y, start, end, cid))
        self.retained_pixels += count
        work["currentRetainedDetailedPixelCount"] += count
        work["currentRetainedDetailedSpanCount"] += 1
        work["peakRetainedDetailedPixelCount"] = max(
            work["peakRetainedDetailedPixelCount"],
            work["currentRetainedDetailedPixelCount"])
        work["peakRetainedDetailedSpanCount"] = max(
            work["peakRetainedDetailedSpanCount"],
            work["currentRetainedDetailedSpanCount"])

    def absorb(self, other, limit, work):
        self.area += other.area
        self.minx = min(self.minx, other.minx)
        self.miny = min(self.miny, other.miny)
        self.maxx = max(self.maxx, other.maxx)
        self.maxy = max(self.maxy, other.maxy)
        self.sumx += other.sumx
        self.sumy += other.sumy
        self.sumx2 += other.sumx2
        self.sumy2 += other.sumy2
        self.sumxy += other.sumxy
        for cid, count in enumerate(other.surface_counts):
            self.surface_counts[cid] += count
        if self.spans is None or other.spans is None or self.area > limit:
            kinds = {self.storage_limit_kind, other.storage_limit_kind}
            kind = "global" if "global" in kinds else "component"
            self.drop_detail(work, kind)
            other.drop_detail(work, kind)
            self.storage_limit_kind = kind
        else:
            self.spans.extend(other.spans)
            self.retained_pixels += other.retained_pixels
            other.spans = None
            other.retained_pixels = 0


def release_component_detail(component, work):
    if component.spans is None:
        return
    work["retainedDetailedPixelCount"] += component.retained_pixels
    work["retainedDetailedSpanCount"] += len(component.spans)
    work["currentRetainedDetailedPixelCount"] -= component.retained_pixels
    work["currentRetainedDetailedSpanCount"] -= len(component.spans)
    component.spans = None
    component.retained_pixels = 0


def _component_root(component):
    root = component
    while root.parent is not root:
        root = root.parent
    while component.parent is not component:
        parent = component.parent
        component.parent = root
        component = parent
    return root


def _merge_components(first, second, limit, work):
    first = _component_root(first)
    second = _component_root(second)
    if first is second:
        return first
    if second.serial < first.serial:
        first, second = second, first
    second.parent = first
    first.absorb(second, limit, work)
    return first


def _sorted_by_serial(components):
    return sorted(components, key=lambda item: item.serial)


def _span_roots(spans):
    return {_component_root(span[2]) for span in spans}


def connected_components(rows, max_candidate_pixels, work):
    """4-connected row-run CCL；上一列 labels + 全域有界 active detailed spans。"""
    previous = []
    previous_y = None
    serial = 0
    for y, row in rows:
        if previous and previous_y is not None and y != previous_y + 1:
            for component in _sorted_by_serial(_span_roots(previous)):
                yield component
            previous = []
        old_roots = _span_roots(previous)
        continuing_roots = set()
        previous_index = 0
        for start, end, _ in row:
            while (previous_index < len(previous)
                   and previous[previous_index][1] <= start):
                previous_index += 1
            scan = previous_index
            while scan < len(previous) and previous[scan][0] < end:
                if previous[scan][1] > start:
                    continuing_roots.add(
                        _component_root(previous[scan][2]))
                scan += 1
        for component in _sorted_by_serial(old_roots - continuing_roots):
            # Consumer analyzes/releases before this generator resumes and
            # pending current-row spans consume the global retention budget.
            yield component


        current = []
        previous_index = 0
        left = None
        for start, end, cid in row:
            while (previous_index < len(previous)
                   and previous[previous_index][1] <= start):
                previous_index += 1
            roots = []
            scan = previous_index
            while scan < len(previous) and previous[scan][0] < end:
                if previous[scan][1] > start:
                    roots.append(_component_root(previous[scan][2]))
                scan += 1
            # class 是 evidence，不是幾何邊界：相鄰 gravel/dirt transition 刻意同元件。
            if left is not None and left[1] == start:
                roots.append(_component_root(left[2]))
            roots = _sorted_by_serial(set(roots))
            if roots:
                component = roots[0]
                for other in roots[1:]:
                    component = _merge_components(
                        component, other, max_candidate_pixels, work)
            else:
                component = _SpanComponent(serial)
                serial += 1
            component = _component_root(component)
            component.add_span(
                y, start, end, cid, max_candidate_pixels, work)
            left = (start, end, component)
            current.append(left)

        current_roots = _span_roots(current)
        work["peakActiveComponentCount"] = max(
            work["peakActiveComponentCount"], len(current_roots))
        previous = current
        previous_y = y

    for component in _sorted_by_serial(_span_roots(previous)):
        yield component


def principal_axis(component):
    n = float(component.area)
    mx = component.sumx / n
    my = component.sumy / n
    cxx = max(0.0, component.sumx2 / n - mx * mx)
    cyy = max(0.0, component.sumy2 / n - my * my)
    cxy = component.sumxy / n - mx * my
    delta = math.hypot(cxx - cyy, 2.0 * cxy)
    l1 = (cxx + cyy + delta) / 2.0
    l2 = max(0.0, (cxx + cyy - delta) / 2.0)
    if abs(cxy) > 1e-9:
        vx, vy = cxy, l1 - cxx
    elif cyy > cxx:
        vx, vy = 0.0, 1.0
    else:
        vx, vy = 1.0, 0.0
    norm = math.hypot(vx, vy) or 1.0
    return mx, my, vx / norm, vy / norm, l1, l2


def _aggregate_component_profile(component, mx, my, vx, vy, l1, l2, ratio):
    corners = (
        (component.minx, component.miny),
        (component.minx, component.maxy),
        (component.maxx, component.miny),
        (component.maxx, component.maxy),
    )
    projected = [
        (x - mx) * vx + (y - my) * vy for x, y in corners]
    first = min(projected)
    last = max(projected)
    length = max(1.0, last - first + 1.0)
    width = component.area / length
    return {
        "status": "aggregate",
        "polyline": [
            (mx + first * vx, my + first * vy),
            (mx + last * vx, my + last * vy),
        ],
        "widths": [width, width],
        "length": length,
        "ratio": ratio,
        "l1": l1,
        "l2": l2,
    }


def profile_component(component):
    mx, my, vx, vy, l1, l2 = principal_axis(component)
    ratio = l1 / max(l2, 1e-9)
    if component.spans is None:
        return _aggregate_component_profile(
            component, mx, my, vx, vy, l1, l2, ratio)

    bins = {}
    component.spans.sort()
    # vx≈0 時主軸垂直：整條 row span 落在同一個 bin，可免逐像素投影。
    axis_is_vertical = abs(vx) <= 1e-12
    for y, start, end, _ in component.spans:
        if axis_is_vertical:
            t = (y - my) * vy
            k = int(math.floor(t + 0.5))
            s0 = (start - mx) * (-vy) + (y - my) * vx
            s1 = (end - 1 - mx) * (-vy) + (y - my) * vx
            lo, hi = min(s0, s1), max(s0, s1)
            span = bins.get(k)
            if span is None:
                if len(bins) >= MAX_CANDIDATE_POLYLINE_POINTS:
                    return _aggregate_component_profile(
                        component, mx, my, vx, vy, l1, l2, ratio)
                bins[k] = [lo, hi]
            else:
                span[0] = min(span[0], lo)
                span[1] = max(span[1], hi)
            continue
        for x in range(start, end):
            t = (x - mx) * vx + (y - my) * vy
            s = (x - mx) * (-vy) + (y - my) * vx
            k = int(math.floor(t + 0.5))
            span = bins.get(k)
            if span is None:
                if len(bins) >= MAX_CANDIDATE_POLYLINE_POINTS:
                    return _aggregate_component_profile(
                        component, mx, my, vx, vy, l1, l2, ratio)
                bins[k] = [s, s]
            else:
                span[0] = min(span[0], s)
                span[1] = max(span[1], s)
    keys = sorted(bins)
    widths = []
    polyline = []
    for k in keys:
        smin, smax = bins[k]
        widths.append(smax - smin + 1.0)
        smid = (smin + smax) / 2.0
        polyline.append(
            (mx + k * vx + smid * (-vy),
             my + k * vy + smid * vx))
    return {
        "status": "detailed",
        "polyline": polyline,
        "widths": widths,
        "length": float(keys[-1] - keys[0] + 1) if keys else 0.0,
        "ratio": ratio,
        "l1": l1,
        "l2": l2,
    }


def _consume_candidate_graph_work(work):
    if work is None:
        return
    next_count = work["candidateGraphWorkCount"] + 1
    if next_count > MAX_CANDIDATE_GRAPH_WORK:
        raise AuditError("candidate graph work 最多 %d，得到 %d" % (
            MAX_CANDIDATE_GRAPH_WORK, next_count))
    work["candidateGraphWorkCount"] = next_count


def nearest_graph_segment(px, py, graph, work=None):
    indices = range(len(graph["segments"]))
    best_distance = math.inf
    best_segment = None
    best_tie = None
    for index in indices:
        _consume_candidate_graph_work(work)
        segment = graph["segments"][index]
        ax, ay, bx, by = segment["coords"]
        distance = dist_point_seg(px, py, ax, ay, bx, by)
        tie = (segment["id"], ax, ay, bx, by)
        if (distance < best_distance - 1e-12
                or (abs(distance - best_distance) <= 1e-12
                    and (best_tie is None or tie < best_tie))):
            best_distance = distance
            best_segment = segment
            best_tie = tie
    return best_distance, best_segment


def graph_parallel_profile(polyline, graph, work=None):
    parallel_count = 0
    max_distance = 0.0
    cos_15 = math.cos(math.radians(15.0))
    size = graph["bucketSize"]
    for index, (x, y) in enumerate(polyline):
        if len(polyline) == 1:
            tx = ty = 0.0
        elif index == 0:
            tx = polyline[1][0] - x
            ty = polyline[1][1] - y
        elif index == len(polyline) - 1:
            tx = x - polyline[index - 1][0]
            ty = y - polyline[index - 1][1]
        else:
            tx = polyline[index + 1][0] - polyline[index - 1][0]
            ty = polyline[index + 1][1] - polyline[index - 1][1]
        tangent_norm = math.hypot(tx, ty)
        key = (int(math.floor(x / size)), int(math.floor(y / size)))
        indices = graph["buckets"].get(key, ())
        nearest_distance = math.inf
        has_parallel = False
        for segment_index in indices:
            _consume_candidate_graph_work(work)
            segment = graph["segments"][segment_index]
            ax, ay, bx, by = segment["coords"]
            distance = dist_point_seg(x, y, ax, ay, bx, by)
            nearest_distance = min(nearest_distance, distance)
            if distance > GATE_CONNECT or tangent_norm <= 1e-12:
                continue
            sx, sy = bx - ax, by - ay
            segment_norm = math.hypot(sx, sy)
            if segment_norm <= 1e-12:
                continue
            dot = abs(tx * sx + ty * sy) / (tangent_norm * segment_norm)
            if dot >= cos_15:
                has_parallel = True
        max_distance = max(max_distance, nearest_distance)
        if has_parallel:
            parallel_count += 1
    return parallel_count / float(len(polyline)), max_distance


def analyze_component(component, surface, graph, surface_fingerprint, xml_sha,
                      work=None, region_bounds=None):
    area = component.area
    if area < MIN_COMPONENT_AREA:
        return None
    minx, maxx = component.minx, component.maxx
    miny, maxy = component.miny, component.maxy
    bw = maxx - minx + 1
    bh = maxy - miny + 1
    fill = area / float(bw * bh)
    aspect = max(bw, bh) / float(max(1, min(bw, bh)))
    prof = profile_component(component)
    polyline = prof["polyline"]
    widths = prof["widths"]
    if not polyline or not widths:
        return None
    length = prof["length"]
    median = quantile(widths, 0.5)
    p10 = quantile(widths, 0.1)
    p90 = quantile(widths, 0.9)
    surface_counts = {
        name: component.surface_counts[cid]
        for cid, name in enumerate(CLASSES)
    }
    dominant_id = max(
        range(len(CLASSES)),
        key=lambda cid: (component.surface_counts[cid], -cid))
    dominant_surface = CLASSES[dominant_id]
    surface_purity = component.surface_counts[dominant_id] / float(area)
    cand_n = sum(
        1 for x, y in polyline if surface.at(x, y) in CANDIDATE_IDS)
    coverage = cand_n / float(len(polyline))
    d0, segment0 = nearest_graph_segment(
        polyline[0][0], polyline[0][1], graph, work=work)
    d1, segment1 = nearest_graph_segment(
        polyline[-1][0], polyline[-1][1], graph, work=work)
    segment0_id = segment0["id"] if segment0 is not None else None
    segment1_id = segment1["id"] if segment1 is not None else None
    same_segment = bool(segment0 is not None and segment0 is segment1)
    ends = int(d0 <= GATE_CONNECT) + int(d1 <= GATE_CONNECT)
    parallel_ratio, max_graph_distance = graph_parallel_profile(
        polyline, graph, work=work)
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
    if surface_purity < 0.8:
        reasons.append("surfaceImpure")
    if min(d0, d1) > GATE_CONNECT:
        reasons.append("unconnected")
    if ends < 2:
        reasons.append("unverifiedTerminus")
    elif same_segment:
        reasons.append("sameAttachment")
    if prof["ratio"] < 4.0 and area >= 64:
        reasons.append("noLongAxis")
    min_side = min(bw, bh)
    if (p90 > GATE_WIDTH_HI and prof["ratio"] < 6.0) or (
            fill >= 0.6 and aspect < 2.0 and min_side >= 16):
        reasons.append("field")
    if aspect < 2.5 and min_side >= 16 and fill < 0.55 and p90 > GATE_WIDTH_HI:
        reasons.append("courtyard")
    if parallel_ratio >= 0.8:
        reasons.append("parallelResidual")
    if boundary_truncated:
        reasons.append("boundaryTruncated")
    if prof["status"] == "aggregate":
        reasons.append("storageLimit")
    if ends == 2:
        confidence = "high"
    elif ends == 1:
        confidence = "low"
    else:
        confidence = "none"
    qpoly = [[r3(x), r3(y)] for x, y in polyline]
    polyline_q2 = [[q2(x), q2(y)] for x, y in qpoly]
    bbox = {"x0": minx, "y0": miny, "x1": maxx, "y1": maxy}
    connection = {
        "d0": r3(1e9 if math.isinf(d0) else d0),
        "d1": r3(1e9 if math.isinf(d1) else d1),
        "endsWithin8": ends,
        "nearestSegment0Id": segment0_id,
        "nearestSegment1Id": segment1_id,
        "sameSegment": same_segment,
    }
    rounded_max_graph_distance = r3(
        1e9 if math.isinf(max_graph_distance) else max_graph_distance)
    candidate = {
        "evidenceVersion": 2,
        "polyline": qpoly,
        "polylineQ2": polyline_q2,
        "length": r3(length),
        "widthMedian": r3(median),
        "widthP10": r3(p10),
        "widthP90": r3(p90),
        "coverage": r3(coverage),
        "area": area,
        "bbox": bbox,
        "surfaceCounts": surface_counts,
        "dominantSurface": dominant_surface,
        "surfacePurity": r3(surface_purity),
        "connection": connection,
        "parallelToGraphRatio": r3(parallel_ratio),
        "maxGraphDistance": rounded_max_graph_distance,
        "confidence": confidence,
        "boundaryTruncated": boundary_truncated,
        "analysisStatus": prof["status"],
        "accepted": not reasons,
        "rejectionReasons": reasons,
    }
    evidence = {
        "version": candidate["evidenceVersion"],
        "source": {
            "surfaceFingerprint": surface_fingerprint,
            "xmlSha256": xml_sha,
        },
        "candidate": candidate,
    }
    evidence_hash = hashlib.sha256(
        dumps_canonical(evidence).encode("utf-8")).hexdigest()
    return {
        "id": "c:" + evidence_hash,
        "evidenceHash": evidence_hash,
        **candidate,
    }


def build_report(streets, surfaces_loaded, surface, xml_sha, surface_sha,
                 max_candidate_pixels=DEFAULT_MAX_CANDIDATE_PIXELS):
    max_candidate_pixels = _validate_candidate_pixel_limit(
        max_candidate_pixels)
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
    railroad_n = sum(
        1 for st in streets
        if len(st["pts"]) >= 2
        and is_railroad(st["name"], st["pts"][0][0], st["pts"][0][1]))
    topology_work = {}
    findings = topology_findings(streets, topology_work)
    kind_n = collections.Counter(finding["kind"] for finding in findings)
    empty_n = kind_n["emptyName"]
    short_n = kind_n["short"]
    zero_n = kind_n["zeroLength"]
    dup_n = kind_n["duplicate"]
    comp_count, comp_sizes = raw_exact_vertex_components(streets)

    samples = []
    total_probe_count = 0
    missing_probe_count = 0
    for i, st in enumerate(streets):
        pts = st["pts"]
        if len(pts) < 2:
            continue
        rail = is_railroad(st["name"], pts[0][0], pts[0][1])
        for k in range(len(pts) - 1):
            x0, y0 = pts[k]
            x1, y1 = pts[k + 1]
            sampled = sample_segment(surface, x0, y0, x1, y1, st["width"])
            total_probe_count += sampled["sampleCount"]
            missing_probe_count += sampled["missingCount"]
            samples.append({
                "id": "s:%d:%d" % (i, k),
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

    pixel_count = count_candidate_pixels(surface)
    covered = paint_coverage(streets, surface_bounds)
    graph = graph_segments(streets, surface_bounds)
    region_bounds = surface_bounds if scope["mode"] == "region" else None
    work = {
        "uncoveredPixelCount": 0,
        "rowSpanCount": 0,
        "peakActiveComponentCount": 0,
        "componentCount": 0,
        "smallComponentCount": 0,
        "storageLimitedComponentCount": 0,
        "componentLimitedComponentCount": 0,
        "globalBudgetLimitedComponentCount": 0,
        "maxComponentArea": 0,
        "globalRetentionBudgetPixels": max_candidate_pixels,
        "currentRetainedDetailedPixelCount": 0,
        "currentRetainedDetailedSpanCount": 0,
        "peakRetainedDetailedPixelCount": 0,
        "peakRetainedDetailedSpanCount": 0,
        "retainedDetailedPixelCount": 0,
        "retainedDetailedSpanCount": 0,
        "candidateGraphWorkCount": 0,
        "profileWorkCount": 0,
        "candidatePolylinePointCount": 0,
        "edgeRejectedCandidateCount": 0,
    }
    candidates = []
    # 兩輪收集：
    #   pass 1（primary）＝全 candidate 集（含 dirt-edge）——edge 格必須照舊
    #   收進 span，否則 v1 的 dirt 大面被 edge 帶挖洞碎裂、候選數 ×5（22319，
    #   recon 實證）且審計報告灌爆；連通形狀與 v1 逐格相同。
    #   pass 2（edge 獨輪）＝只認 dirt-edge——窄土徑帶不與曠野 dirt 連通，
    #   才能成為獨立窄帶 component（與 primary 同輪收集時零新候選，首跑實證）。
    # work 計數與各上限跨輪累計；候選 id=證據 hash，兩輪幾何不同不相撞。
    for edge_pass, pass_ids in (
            (False, CANDIDATE_IDS), (True, EDGE_CANDIDATE_IDS)):
        rows = candidate_rows(surface, covered, work, pass_ids)
        for component in connected_components(rows, max_candidate_pixels, work):
            next_component_count = work["componentCount"] + 1
            if next_component_count > MAX_COMPONENTS:
                raise AuditError("candidate components 最多 %d，得到 %d" % (
                    MAX_COMPONENTS, next_component_count))
            work["componentCount"] = next_component_count
            work["maxComponentArea"] = max(
                work["maxComponentArea"], component.area)
            if component.storage_limited:
                work["storageLimitedComponentCount"] += 1
                if component.storage_limit_kind == "global":
                    work["globalBudgetLimitedComponentCount"] += 1
                else:
                    work["componentLimitedComponentCount"] += 1
            # edge 輪線性預過濾：bbox 對角 < GATE_LENGTH 的團塊（裸泥塊邊緣圈、
            # 小 patch）不可能過 accepted 的 length gate，提前釋放。
            if edge_pass and component.minx is not None:
                bw = component.maxx - component.minx + 1
                bh = component.maxy - component.miny + 1
                if bw * bw + bh * bh < GATE_LENGTH * GATE_LENGTH:
                    release_component_detail(component, work)
                    work["smallComponentCount"] += 1
                    continue
            if (component.area >= MIN_COMPONENT_AREA
                    and len(candidates) >= MAX_REPORTED_CANDIDATES):
                raise AuditError("reported candidates 最多 %d，得到 %d" % (
                    MAX_REPORTED_CANDIDATES, len(candidates) + 1))
            if component.spans is not None:
                next_profile_work = work["profileWorkCount"] + component.area
                if next_profile_work > MAX_TOTAL_PROFILE_WORK:
                    raise AuditError("candidate profile work 最多 %d，得到 %d" % (
                        MAX_TOTAL_PROFILE_WORK, next_profile_work))
                work["profileWorkCount"] = next_profile_work
            item = analyze_component(
                component, surface, graph, surface_sha, xml_sha, work=work,
                region_bounds=region_bounds)
            release_component_detail(component, work)
            if item is None:
                work["smallComponentCount"] += 1
            elif edge_pass and not item["accepted"]:
                # edge 輪被 gate 拒者只計數不入報告：全圖裸泥塊邊緣圈上萬
                # （寬 1-2 格、被 medianWidth gate 拒），全報會撞 reported
                # 上限並灌爆 JSON。primary 輪維持全報（審計完整性不變）。
                work["edgeRejectedCandidateCount"] += 1
            else:
                next_polyline_points = (
                    work["candidatePolylinePointCount"] + len(item["polyline"]))
                if next_polyline_points > MAX_TOTAL_CANDIDATE_POLYLINE_POINTS:
                    raise AuditError(
                        "candidate polyline points 最多 %d，得到 %d" % (
                            MAX_TOTAL_CANDIDATE_POLYLINE_POINTS,
                            next_polyline_points))
                work["candidatePolylinePointCount"] = next_polyline_points
                candidates.append(item)
    candidates.sort(key=lambda c: (c["id"], c["bbox"]["y0"], c["bbox"]["x0"]))
    accepted_count = sum(1 for item in candidates if item["accepted"])
    aggregate_count = sum(
        1 for item in candidates if item["analysisStatus"] == "aggregate")
    candidate_analysis = {
        "status": "partial" if scope["mode"] == "region" else "ok",
        "pixelCount": pixel_count,
        "limit": max_candidate_pixels,
        "limitScope": "perComponentAndGlobalRetainedPixels",
        "globalRetentionBudgetPixels": max_candidate_pixels,
        "algorithm": "rowSpanStreaming",
        "coverageSpanCount": sum(len(spans) for spans in covered.values()),
        "uncoveredPixelCount": work["uncoveredPixelCount"],
        "maskedPixelCount": pixel_count - work["uncoveredPixelCount"],
        "rowSpanCount": work["rowSpanCount"],
        "componentCount": work["componentCount"],
        "edgeRejectedCandidateCount": work["edgeRejectedCandidateCount"],
        "componentLimit": MAX_COMPONENTS,
        "reportedCandidateLimit": MAX_REPORTED_CANDIDATES,
        "candidateGraphWorkCount": work["candidateGraphWorkCount"],
        "candidateGraphWorkLimit": MAX_CANDIDATE_GRAPH_WORK,
        "candidateGraphBucketReferenceCount": graph["bucketReferenceCount"],
        "candidateGraphBucketReferenceLimit":
            MAX_CANDIDATE_GRAPH_BUCKET_REFS,
        "profileWorkCount": work["profileWorkCount"],
        "profileWorkLimit": MAX_TOTAL_PROFILE_WORK,
        "candidatePolylinePointCount": work["candidatePolylinePointCount"],
        "candidatePolylinePointLimit":
            MAX_TOTAL_CANDIDATE_POLYLINE_POINTS,
        "smallComponentCount": work["smallComponentCount"],
        "storageLimitedComponentCount": work["storageLimitedComponentCount"],
        "componentLimitedComponentCount": work["componentLimitedComponentCount"],
        "globalBudgetLimitedComponentCount": work[
            "globalBudgetLimitedComponentCount"],
        "retainedDetailedPixelCount": work["retainedDetailedPixelCount"],
        "retainedDetailedSpanCount": work["retainedDetailedSpanCount"],
        "peakRetainedDetailedPixelCount": work[
            "peakRetainedDetailedPixelCount"],
        "peakRetainedDetailedSpanCount": work[
            "peakRetainedDetailedSpanCount"],
        "detailedCandidateCount": len(candidates) - aggregate_count,
        "aggregateCandidateCount": aggregate_count,
        "acceptedCount": accepted_count,
        "rejectedCount": len(candidates) - accepted_count,
        "maxComponentArea": work["maxComponentArea"],
        "peakActiveComponentCount": work["peakActiveComponentCount"],
    }

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
            "work": topology_work,
        },
        "streetSamples": samples,
        "candidateAnalysis": candidate_analysis,
        "candidates": candidates,
    }


def _read_capped_file(path, limit, label):
    source = Path(path)
    size = source.stat().st_size
    if size > limit:
        raise AuditError("%s 檔案不得超過 %d bytes，得到 %d" % (
            label, limit, size))
    data = source.read_bytes()
    if len(data) > limit:
        raise AuditError("%s 檔案不得超過 %d bytes，得到 %d" % (
            label, limit, len(data)))
    return data


def audit(streets_path, surfaces_path, max_candidate_pixels=DEFAULT_MAX_CANDIDATE_PIXELS):
    max_candidate_pixels = _validate_candidate_pixel_limit(
        max_candidate_pixels)
    streets_data = _read_capped_file(
        streets_path, MAX_STREETS_XML_BYTES, "streets XML")
    surfaces_data = _read_capped_file(
        surfaces_path, MAX_SURFACES_JSON_BYTES, "surfaces JSON")
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


def render_preview_bytes(report):
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
    return dumps_canonical(doc).encode("utf-8")


def _stage_bytes(path, data):
    target = Path(path)
    fd, temp_name = tempfile.mkstemp(
        prefix=".%s." % target.name, suffix=".tmp", dir=str(target.parent))
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
    except BaseException:
        if temp_path.exists():
            temp_path.unlink()
        raise
    return temp_path, target


def write_report_outputs(report, out, preview=None):
    canonical_data = dumps_canonical(report).encode("utf-8")
    preview_data = render_preview_bytes(report) if preview is not None else None
    out_temp = None
    preview_temp = None
    preview_committed = False
    try:
        out_temp, out_target = _stage_bytes(out, canonical_data)
        if preview is not None:
            preview_temp, preview_target = _stage_bytes(preview, preview_data)
            os.replace(preview_temp, preview_target)
            preview_committed = True
        try:
            os.replace(out_temp, out_target)
        except OSError as exc:
            if preview_committed:
                raise AuditError(
                    "preview 已更新；canonical out 未更新：%s" % exc) from exc
            raise
    finally:
        for temp_path in (preview_temp, out_temp):
            if temp_path is not None and temp_path.exists():
                temp_path.unlink()


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
        help="單一元件及全域 active detailed spans 像素上限（超限改 aggregate）")
    args = parser.parse_args(argv)
    try:
        reject_path_aliases(args.streets, args.surfaces, args.out, args.preview)
        report = audit(args.streets, args.surfaces,
                       max_candidate_pixels=args.max_candidate_pixels)
        write_report_outputs(report, args.out, args.preview)
    except (AuditError, OSError) as exc:
        sys.stderr.write("%s\n" % exc)
        return 2
    analysis = report["candidateAnalysis"]
    coverage = report["surfaceCoverage"]
    if analysis["storageLimitedComponentCount"]:
        sys.stderr.write(
            "candidate analysis used aggregate evidence for %d component(s) "
            "exceeding --max-candidate-pixels=%d\n" % (
                analysis["storageLimitedComponentCount"], analysis["limit"]))
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
