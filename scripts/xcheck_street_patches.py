#!/usr/bin/env python3
"""Cross-check a third-party street-geometry patch list against our own evidence.

競品（Derpy Autodrive）的 `Vanilla_patch.lua` 手修清單只當「線索」：座標是地圖
事實，但每一筆是否真的是官方 polyline 幾何錯，一律用本 repo 自己的兩份證據重判：

1. vanilla `worldmap.xml` 的 highway 多邊形（cell 座標 ×300 偏移）含點測試＋
   點到多邊形邊緣的距離；
2. `road-surfaces-*.json` raster 在該點 ±1 格窗內的 surface class。

判定（逐頂點）：
    onRoad ⇔ (最近 highway 多邊形內，或外緣 ≤1.0 格) 或 (±1 格窗內有 paved/gravel)
1.0 格的邊緣容差吸收 q2 量化與多邊形逐 cell 切邊的鋸齒——沒有它，正好壓在邊上
的頂點會被誤判成資料錯。
唯一匹配後，rawEvidence 與分類使用官方 XML 頂點；第三方近似座標只用於尋找窗口。

分類：
    confirmed  raw 至少一頂點 offRoad、且 new 每個頂點都 onRoad（真幾何錯＋可用修正）
    cosmetic   raw 全部 onRoad（競品只是為自駕拉直轉角，官方資料沒錯，不收）
    bad-fix    raw offRoad 但 new 驗不過（或 new 為空的純刪頂點）→ 待人工
    ambiguous  raw 頂點序列在 streets.xml 對到 0 或 >1 條街（路口共用頂點）→ 待人工

`confirmed` 再過一道 RoadPatch 可行性閘門，通過者才自動產生 approvals 項目
（`remove` 官方段 id ＋ `manualRoads` add）；不通過者列 `manual`。

街道 XML、audit 與 raster 必須符合 approvals 的指紋；缺格或未支援的 Lua 呼叫形式
明確拒絕。輸出不得覆蓋證據輸入；唯一例外是以原子替換更新原 approvals。
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import sys
import unicodedata
import xml.etree.ElementTree as ET
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import audit_streets as A  # noqa: E402
import gen_road_patches as G  # noqa: E402

CELL = 300
VERTEX_TOL = 0.5          # streets.xml 頂點比對容差（q2 量化級）
EDGE_TOL = 1.0            # 多邊形外緣容差；超過才算真的在路面外
ON_ROAD_CLASSES = frozenset({"paved", "gravel"})
SURFACE_MAP = {
    "paved": "paved",
    "gravel": "gravel",
    "dirt-candidate": "dirt",
    "dirt-edge": "dirt",
    "natural": "unknown",
    "unknown": "unknown",
}
EXT_MATCH_RADIUS = 6.0    # 第二階段：ext 街道與 candidate polyline 的重疊判定半徑


class XcheckError(RuntimeError):
    pass


# --------------------------------------------------------------------------
# 輸入解析
# --------------------------------------------------------------------------

PATCH_RE = re.compile(
    r'\badd_xml_patch\s*\(\s*"Vanilla"\s*,\s*nil\s*,\s*\{([^}]*)\}\s*,\s*\{([^}]*)\}\s*\)'
)
NUM_RE = re.compile(r"-?[0-9]+(?:\.[0-9]+)?")
LUA_TOKEN_RE = re.compile(
    r"(?P<block_comment>--\[(?P<comment_eq>=*)\[.*?\](?P=comment_eq)\])"
    r"|(?P<line_comment>--[^\r\n]*)"
    r"""|(?P<string>"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')"""
    r"|(?P<long_string>\[(?P<string_eq>=*)\[.*?\](?P=string_eq)\])"
    rf"|(?P<patch>{PATCH_RE.pattern})", re.S,
)


def _pairs(text: str, where: str) -> list[tuple[float, float]]:
    tokens = text.split(",")
    if not tokens[-1].strip():
        tokens.pop()
    if any(NUM_RE.fullmatch(token.strip()) is None for token in tokens):
        raise XcheckError(f"{where}: coordinates must be decimal literals ({text!r})")
    values = [float(token) for token in tokens]
    if len(values) % 2 or not all(math.isfinite(value) for value in values):
        raise XcheckError(f"{where}: coordinate list is not finite/pairwise ({text!r})")
    return [(values[i], values[i + 1]) for i in range(0, len(values), 2)]


def parse_derpy_patches(text: str) -> tuple[list[dict], list[dict]]:
    """解析 literal patch calls；註解中的呼叫列為 disabled，字串中的範例不算呼叫。"""
    active: list[dict] = []
    disabled: list[dict] = []
    street = None
    offset, lineno = 0, 1

    def check_gap(gap, line):
        if re.search(r"""\badd_xml_patch\b|["']|\[=*\[""", gap):
            raise XcheckError(f"line {line}: unsupported or unterminated Lua text")

    for token in LUA_TOKEN_RE.finditer(text):
        gap = text[offset:token.start()]
        check_gap(gap, lineno)
        lineno += gap.count("\n")
        chunk = token.group()
        commented = token.group("block_comment") is not None or token.group("line_comment") is not None
        if token.group("line_comment") is not None and re.match(r"--\[=*\[", chunk):
            raise XcheckError(f"line {lineno}: unterminated Lua block comment")
        if commented or token.group("patch") is not None:
            matches = list(PATCH_RE.finditer(chunk))
            if not matches and token.group("line_comment") is not None:
                name = re.fullmatch(r"--\s*(\S.*?)\s*", chunk)
                if name:
                    street = name.group(1)
            for match in matches:
                line = lineno + chunk.count("\n", 0, match.start())
                entry = {
                    "line": line,
                    "street": street,
                    "raw": _pairs(match.group(1), f"line {line} raw"),
                    "new": _pairs(match.group(2), f"line {line} new"),
                }
                if not entry["raw"]:
                    raise XcheckError(f"line {line}: empty raw vertex list")
                (disabled if commented else active).append(entry)
        lineno += chunk.count("\n")
        offset = token.end()
    check_gap(text[offset:], lineno)
    return active, disabled


EXT_STREET_RE = re.compile(
    r'<street\s+name="([^"]*)"\s+width="([\d.]+)"\s*>(.*?)</street>', re.S)
EXT_POINT_RE = re.compile(r'<point\s+x="(-?[\d.]+)"\s+y="(-?[\d.]+)"')


def parse_ext_streets(text: str) -> list[dict]:
    """`Vanilla_ext.lua` 內嵌的 streets XML 長字串。

    競品那份 XML 有一批 `<point …>` 忘了自閉合（PZ 自家 parser 容忍），
    ElementTree 會直接爆 mismatched tag，所以這裡用寬鬆的 regex 取值。
    """
    out: list[dict] = []
    for block in re.findall(r"\[\[(.*?)\]\]", text, re.S):
        if "<streets" not in block:
            continue
        for name, width, body in EXT_STREET_RE.findall(block):
            pts = [(float(x), float(y)) for x, y in EXT_POINT_RE.findall(body)]
            if len(pts) >= 2:
                out.append({"name": name, "width": float(width), "pts": pts})
    return out


def load_highway_polygons(path: Path) -> dict[tuple[int, int], list[tuple[str, list]]]:
    root = ET.parse(path).getroot()
    index: dict[tuple[int, int], list[tuple[str, list]]] = {}
    for cell in root:
        if cell.tag != "cell":
            continue
        ox = int(cell.get("x")) * CELL
        oy = int(cell.get("y")) * CELL
        for feature in cell:
            props = feature.find("properties")
            kind = None
            if props is not None:
                for prop in props:
                    if prop.get("name") == "highway":
                        kind = prop.get("value")
            if kind is None:
                continue
            geometry = feature.find("geometry")
            if geometry is None or geometry.get("type") != "Polygon":
                continue
            poly = [
                (float(point.get("x")) + ox, float(point.get("y")) + oy)
                for point in geometry.find("coordinates")
            ]
            if len(poly) >= 3:
                index.setdefault((ox // CELL, oy // CELL), []).append((kind, poly))
    if not index:
        raise XcheckError("worldmap.xml contains no highway polygons")
    return index


# --------------------------------------------------------------------------
# 證據
# --------------------------------------------------------------------------

def _point_in_polygon(px: float, py: float, poly: list[tuple[float, float]]) -> bool:
    inside = False
    count = len(poly)
    for i in range(count):
        ax, ay = poly[i]
        bx, by = poly[(i + 1) % count]
        if (ay > py) != (by > py):
            if px < ax + (py - ay) / (by - ay) * (bx - ax):
                inside = not inside
    return inside


def _polygon_edge_distance(px: float, py: float, poly: list[tuple[float, float]]) -> float:
    count = len(poly)
    return min(
        A.dist_point_seg(px, py, poly[i][0], poly[i][1],
                         poly[(i + 1) % count][0], poly[(i + 1) % count][1])
        for i in range(count)
    )


class Evidence:
    def __init__(self, polygons, surface_index):
        self.polygons = polygons
        self.surface = surface_index

    def _nearby(self, px: float, py: float):
        cx = int(math.floor(px)) // CELL
        cy = int(math.floor(py)) // CELL
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                bucket = self.polygons.get((cx + dx, cy + dy))
                if bucket:
                    yield from bucket

    def surface_class(self, px: float, py: float) -> str:
        class_id = self.surface.at(int(math.floor(px)), int(math.floor(py)))
        if class_id is A.MISSING:
            raise XcheckError(f"missing surface evidence at ({px:g},{py:g})")
        if not 0 <= class_id < len(A.CLASSES):
            raise XcheckError(f"invalid surface class at ({px:g},{py:g}): {class_id!r}")
        return A.CLASSES[class_id]

    def probe(self, px: float, py: float) -> dict:
        """單點證據：多邊形歸屬／邊緣距離（內為正、外為負）＋ raster ±1 格窗。"""
        best = None
        for kind, poly in self._nearby(px, py):
            inside = _point_in_polygon(px, py, poly)
            distance = _polygon_edge_distance(px, py, poly)
            rank = (0 if inside else 1, -distance if inside else distance)
            if best is None or rank < best[0]:
                best = (rank, kind, inside, distance)
        if best is None:
            poly_kind, poly_inside, signed = None, False, None
        else:
            _, poly_kind, poly_inside, distance = best
            signed = round(distance if poly_inside else -distance, 3)
        window = sorted({
            self.surface_class(px + dx, py + dy)
            for dx in (-1, 0, 1) for dy in (-1, 0, 1)
        })
        raster_on = any(name in ON_ROAD_CLASSES for name in window)
        polygon_on = best is not None and (poly_inside or distance <= EDGE_TOL)
        return {
            "x": px,
            "y": py,
            "polygonKind": poly_kind,
            "polygonEdgeDistance": signed,
            "polygonInside": poly_inside,
            "surfaceClass": self.surface_class(px, py),
            "surfaceWindow": window,
            "rasterOnRoad": raster_on,
            "polygonOnRoad": polygon_on,
            "onRoad": polygon_on or raster_on,
        }

    def polyline_surface(self, points: list[tuple[float, float]]) -> tuple[str, dict[str, int]]:
        counts: dict[str, int] = {}
        for index in range(len(points) - 1):
            (x0, y0), (x1, y1) = points[index], points[index + 1]
            steps = max(1, int(round(math.hypot(x1 - x0, y1 - y0))))
            for step in range(steps + 1):
                t = step / steps
                name = self.surface_class(x0 + (x1 - x0) * t, y0 + (y1 - y0) * t)
                counts[name] = counts.get(name, 0) + 1
        if not counts:
            return "unknown", counts
        dominant = max(counts, key=lambda name: (counts[name], name))
        return SURFACE_MAP.get(dominant, "unknown"), counts


# --------------------------------------------------------------------------
# streets.xml 對位
# --------------------------------------------------------------------------

def usable_streets(streets: list[dict], target_src: str) -> list[dict]:
    """非鐵路街道＋ segment id 前綴（與 gen_road_patches 同一套指紋）。"""
    out = []
    for index, street in enumerate(streets):
        first = street["pts"][0]
        if A.is_railroad(street["name"], first[0], first[1]):
            continue
        flat = [value for point in street["pts"] for value in point]
        compact = G.compact_geometry_key(target_src, G.geometry_key(flat))
        out.append({
            "streetIndex": index,
            "name": street["name"],
            "width": street["width"],
            "pts": street["pts"],
            "compact": compact,
        })
    return out


def match_run(raw: list[tuple[float, float]], name: str | None,
              streets: list[dict]) -> list[dict]:
    """在官方 polyline 找出 raw 的連續頂點序列（競品序列可能與 XML 反向）。"""
    hits: list[dict] = []
    directions = (False,) if len(raw) == 1 else (False, True)
    for reversed_run in directions:
        sequence = raw[::-1] if reversed_run else raw
        for street in streets:
            pts = street["pts"]
            for start in range(len(pts) - len(sequence) + 1):
                if all(
                    abs(pts[start + offset][0] - sequence[offset][0]) <= VERTEX_TOL
                    and abs(pts[start + offset][1] - sequence[offset][1]) <= VERTEX_TOL
                    for offset in range(len(sequence))
                ):
                    hits.append({"street": street, "start": start, "reversed": reversed_run})
    if name:
        named = [hit for hit in hits if hit["street"]["name"] == name]
        if named:
            return named
    return hits


# --------------------------------------------------------------------------
# approvals 產生
# --------------------------------------------------------------------------

def slugify(name: str) -> str:
    ascii_name = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode()
    slug = re.sub(r"[^a-z0-9]+", "-", ascii_name.lower()).strip("-")
    return slug or "street"


def plan_patch(entry: dict, evidence: Evidence) -> dict:
    """把一筆 confirmed 線索轉成 RoadPatch 計畫（或說明為何不可行）。"""
    hit = entry["match"]
    street = hit["street"]
    pts = street["pts"]
    segment_count = len(pts) - 1
    start = hit["start"]
    length = len(entry["raw"])
    replacement = entry["new"][::-1] if hit["reversed"] else list(entry["new"])

    low = max(0, start - 1)
    high = min(segment_count - 1, start + length - 1)
    removed = list(range(low, high + 1))
    kept = segment_count - len(removed)
    if kept < 1:
        return {"feasible": False,
                "blocker": f"移除 {len(removed)}/{segment_count} 段後無官方段可保留（街道搜尋會失效）"}

    points: list[tuple[float, float]] = []
    if start > 0:
        anchor = pts[start - 1]
        head = replacement[0]
        drift = A.dist_point_seg(head[0], head[1], anchor[0], anchor[1],
                                 pts[start][0], pts[start][1])
        if drift > EDGE_TOL:
            return {"feasible": False,
                    "blocker": f"取代折線起點離被移除的官方段 {start - 1} 有 {drift:.3f} 格，無法併節點"}
        points.append(anchor)
    points.extend(replacement)
    if start + length <= segment_count:
        anchor = pts[start + length]
        tail = replacement[-1]
        drift = A.dist_point_seg(tail[0], tail[1],
                                 pts[start + length - 1][0], pts[start + length - 1][1],
                                 anchor[0], anchor[1])
        if drift > EDGE_TOL:
            return {"feasible": False,
                    "blocker": f"取代折線尾點離被移除的官方段 {start + length - 1} 有 {drift:.3f} 格，無法併節點"}
        points.append(anchor)
    if len(points) < 2:
        return {"feasible": False, "blocker": "取代折線不足兩點"}

    width = float(street["width"])
    if not 2.0 <= width <= 8.0:
        return {"feasible": False,
                "blocker": f"官方 width {width:g} 超出 manualRoads 值域 2..8"}

    surface, counts = evidence.polyline_surface(points)
    return {
        "feasible": True,
        "removeSegments": removed,
        "removeIds": [G.segment_id(street["compact"], index) for index in removed],
        "keptSegments": [i for i in range(segment_count) if i not in set(removed)],
        "points": [value for point in points for value in point],
        "width": width,
        "surface": surface,
        "surfaceCounts": counts,
    }


def _fmt(value: float) -> str:
    return f"{value:g}"


def build_reason(entry: dict, plan: dict) -> str:
    street = entry["match"]["street"]
    bad = [ev for ev in entry["rawEvidence"] if not ev["onRoad"]]
    bits = []
    for ev in bad:
        near = ev["polygonKind"] or "無"
        dist = "無多邊形" if ev["polygonEdgeDistance"] is None else f"{ev['polygonEdgeDistance']:+.3f}"
        bits.append(
            f"({_fmt(ev['x'])},{_fmt(ev['y'])}) 距最近 highway={near} 多邊形邊緣 {dist} 格、"
            f"raster class={ev['surfaceClass']}、±1 格窗={'/'.join(ev['surfaceWindow'])}"
        )
    good = [
        f"({_fmt(ev['x'])},{_fmt(ev['y'])})={ev['surfaceClass']}"
        for ev in entry["newEvidence"]
    ]
    return (
        f"{street['name']} 官方 polyline 幾何錯（自動交叉驗證，線索來源：第三方手修清單座標，"
        f"判定與幾何全部以本 repo 證據重驗）：streetIndex {street['streetIndex']} 的頂點 "
        f"{', '.join(bits)}——落在真路面外。移除官方段 "
        f"{','.join(str(i) for i in plan['removeSegments'])}、保留段 "
        f"{','.join(str(i) for i in plan['keptSegments'])}（街道仍可搜尋），"
        f"以 {len(plan['points']) // 2} 點折線取代；折線每個頂點經 highway 多邊形＋raster 雙證據"
        f"驗在路面上（new 頂點 class：{', '.join(good)}），端點與保留段端點同座標靠 ATTACH_END 併節點。"
        f"surface={plan['surface']} 取中線取樣 class 眾數實證。"
    )


# --------------------------------------------------------------------------
# 第二階段：ext 街道 × pinned audit candidates
# --------------------------------------------------------------------------

def _polyline_distance(px: float, py: float, pts: list[tuple[float, float]]) -> float:
    return min(
        A.dist_point_seg(px, py, pts[i][0], pts[i][1], pts[i + 1][0], pts[i + 1][1])
        for i in range(len(pts) - 1)
    )


def overlap_ext_candidates(ext: list[dict], audit: dict,
                           decided: set[str]) -> list[dict]:
    boxes = []
    for street in ext:
        xs = [p[0] for p in street["pts"]]
        ys = [p[1] for p in street["pts"]]
        boxes.append((street, min(xs) - EXT_MATCH_RADIUS, min(ys) - EXT_MATCH_RADIUS,
                      max(xs) + EXT_MATCH_RADIUS, max(ys) + EXT_MATCH_RADIUS))
    out = []
    for candidate in audit["candidates"]:
        polyline = candidate.get("polyline") or []
        if len(polyline) < 2:
            continue
        bbox = candidate["bbox"]
        best = None
        for street, x0, y0, x1, y1 in boxes:
            if bbox["x1"] < x0 or bbox["x0"] > x1 or bbox["y1"] < y0 or bbox["y0"] > y1:
                continue
            distances = [
                _polyline_distance(point[0], point[1], street["pts"])
                for point in polyline
            ]
            inside = sum(1 for d in distances if d <= EXT_MATCH_RADIUS)
            if inside * 2 < len(distances):
                continue
            mean = sum(distances) / len(distances)
            rank = (-inside / len(distances), mean, street["name"])
            if best is None or rank < best[0]:
                best = (rank, street, inside, len(distances), mean)
        if best is None:
            continue
        _, street, inside, total, mean = best
        out.append({
            "candidateId": candidate["id"],
            "extStreet": street["name"],
            "extWidth": street["width"],
            "analysisStatus": candidate.get("analysisStatus"),
            "confidence": candidate.get("confidence"),
            "dominantSurface": candidate.get("dominantSurface"),
            "length": candidate.get("length"),
            "coveredPointRatio": round(inside / total, 3),
            "meanDistance": round(mean, 3),
            "alreadyDecided": candidate["id"] in decided,
        })
    out.sort(key=lambda item: (item["extStreet"], item["candidateId"]))
    return out


# --------------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------------

def classify(active: list[dict], streets: list[dict], evidence: Evidence) -> None:
    for entry in active:
        hits = match_run(entry["raw"], entry["street"], streets)
        raw_points = entry["raw"]
        if len(hits) == 1:
            hit = hits[0]
            raw_points = hit["street"]["pts"][hit["start"]:hit["start"] + len(raw_points)]
            if hit["reversed"]:
                raw_points = raw_points[::-1]
        # 容差只用於對位；唯一匹配時，負面證據必須來自官方 XML，而非第三方近似座標。
        entry["rawEvidence"] = [evidence.probe(*point) for point in raw_points]
        entry["newEvidence"] = [evidence.probe(*point) for point in entry["new"]]
        raw_off = [ev for ev in entry["rawEvidence"] if not ev["onRoad"]]
        new_off = [ev for ev in entry["newEvidence"] if not ev["onRoad"]]
        if len(hits) != 1:
            entry["match"] = None
            entry["klass"] = "ambiguous"
            entry["note"] = f"streets.xml 對到 {len(hits)} 條街"
            continue
        entry["match"] = hits[0]
        if not raw_off:
            entry["klass"] = "cosmetic"
            entry["note"] = "raw 頂點全部在路面上（雙證據），官方資料無誤"
        elif not entry["new"]:
            entry["klass"] = "bad-fix"
            entry["note"] = "純刪頂點，無取代幾何可驗"
        elif new_off:
            entry["klass"] = "bad-fix"
            entry["note"] = f"new 有 {len(new_off)} 個頂點驗不過"
        else:
            entry["klass"] = "confirmed"
            entry["note"] = f"raw 有 {len(raw_off)} 個頂點在路面外，new 全部在路面上"


def report_entry(entry: dict, plan: dict | None) -> dict:
    match = entry["match"]
    item = {
        "class": entry["klass"],
        "line": entry["line"],
        "street": entry["street"],
        "note": entry["note"],
        "raw": [list(point) for point in entry["raw"]],
        "new": [list(point) for point in entry["new"]],
        "rawEvidence": entry["rawEvidence"],
        "newEvidence": entry["newEvidence"],
        "rawOffRoadCount": sum(1 for ev in entry["rawEvidence"] if not ev["onRoad"]),
        "newOffRoadCount": sum(1 for ev in entry["newEvidence"] if not ev["onRoad"]),
    }
    if match:
        item["matchedStreet"] = {
            "streetIndex": match["street"]["streetIndex"],
            "name": match["street"]["name"],
            "width": match["street"]["width"],
            "segmentCount": len(match["street"]["pts"]) - 1,
            "vertexStart": match["start"],
            "reversedRun": match["reversed"],
            "compactKey": match["street"]["compact"],
        }
    if plan is not None:
        item["plan"] = plan
    return item


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--patch-lua", required=True, type=Path)
    parser.add_argument("--ext-lua", type=Path)
    parser.add_argument("--streets", required=True, type=Path)
    parser.add_argument("--worldmap", required=True, type=Path)
    parser.add_argument("--surfaces", required=True, type=Path)
    parser.add_argument("--audit", required=True, type=Path)
    parser.add_argument("--approvals", default=SCRIPT_DIR / "road_patch_approvals.json",
                        type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--emit-approvals", type=Path,
                        help="把 confirmed 且可行的項目合進 approvals 後寫出這個路徑")
    args = parser.parse_args(argv)

    inputs = {
        "patch-lua": args.patch_lua, "ext-lua": args.ext_lua, "streets": args.streets,
        "worldmap": args.worldmap, "surfaces": args.surfaces, "audit": args.audit,
        "approvals": args.approvals,
    }
    for output_name, output in (("report", args.out), ("emit-approvals", args.emit_approvals)):
        if output is None:
            continue
        for name, source in inputs.items():
            if source is None or (output_name == "emit-approvals" and name == "approvals"):
                continue  # 唯一允許的原地更新是 approvals，寫入時使用既有原子替換。
            if G._same_file_or_path(output, source):
                raise XcheckError(f"path alias rejected: {output_name} and {name}")
    if args.emit_approvals and G._same_file_or_path(args.out, args.emit_approvals):
        raise XcheckError("path alias rejected: report and emit-approvals")

    streets_raw = args.streets.read_bytes()
    approvals = json.loads(args.approvals.read_text(encoding="utf-8"))
    audit_raw = args.audit.read_bytes()
    surfaces_raw = args.surfaces.read_bytes()
    patch_raw = args.patch_lua.read_bytes()
    ext_raw = args.ext_lua.read_bytes() if args.ext_lua else None
    for name, raw, key in (("audit", audit_raw, "auditSha256"),
                           ("surfaces", surfaces_raw, "auditSurfaceFingerprint")):
        digest = hashlib.sha256(raw).hexdigest()
        if digest != approvals[key]:
            raise XcheckError(f"{name} sha256 {digest} != approvals.{key} {approvals[key]}")
    audit = json.loads(audit_raw)
    xml_sha = hashlib.sha256(streets_raw).hexdigest()
    if xml_sha != approvals["auditXmlSha256"]:
        raise XcheckError(
            f"streets.xml sha256 {xml_sha} != approvals.auditXmlSha256 "
            f"{approvals['auditXmlSha256']}（vanilla 版本不符，先重跑 audit）"
        )
    target_src = approvals["targetSrc"]

    parsed = usable_streets(A.parse_streets(streets_raw), target_src)
    evidence = Evidence(
        load_highway_polygons(args.worldmap),
        A.SurfaceIndex(A.load_surfaces(surfaces_raw)),
    )
    active, disabled = parse_derpy_patches(patch_raw.decode("utf-8"))
    classify(active, parsed, evidence)

    existing_roads = {road["id"]: road for road in approvals["manualRoads"]}
    existing_removes = set(approvals["remove"])

    # 同一街多個 confirmed 窗口：先算全街移除聯集，避免整條街被掃空
    per_street: dict[int, list[dict]] = {}
    for entry in active:
        if entry["klass"] == "confirmed":
            per_street.setdefault(entry["match"]["street"]["streetIndex"], []).append(entry)

    items: list[dict] = []
    new_roads: list[dict] = []
    new_removes: list[str] = []
    manual: list[dict] = []
    already: list[dict] = []
    slug_seq: dict[str, int] = {}

    for entry in active:
        if entry["klass"] != "confirmed":
            items.append(report_entry(entry, None))
            continue
        street = entry["match"]["street"]
        plan = plan_patch(entry, evidence)
        siblings = per_street[street["streetIndex"]]
        if plan["feasible"]:
            union = set(plan["removeSegments"])
            if len(siblings) > 1:
                union = set()
                for sibling in siblings:
                    sibling_plan = plan_patch(sibling, evidence)
                    if not sibling_plan["feasible"]:
                        continue
                    window = set(sibling_plan["removeSegments"])
                    if union & window:
                        plan = {"feasible": False,
                                "blocker": "同一街有相鄰／重疊的取代窗口，需人工合併成單一折線"}
                        break
                    union |= window
            union.update(i for i in range(len(street["pts"]) - 1)
                         if G.segment_id(street["compact"], i) in existing_removes)
            kept = [i for i in range(len(street["pts"]) - 1) if i not in union]
            if not kept:
                plan = {"feasible": False, "blocker": "合併既有移除段後無官方段可保留"}
            elif plan["feasible"]:
                plan["keptSegments"] = kept

        if plan["feasible"]:
            slug = slugify(street["name"])
            slug_seq[slug] = slug_seq.get(slug, 0) + 1
            identity = f"m:muldraugh-{slug}-{slug_seq[slug]}"
            road = {
                "operation": "add", "points": plan["points"], "width": plan["width"],
                "surface": plan["surface"], "searchable": False,
            }
            same = next((old for old in existing_roads.values()
                         if all(old.get(key) == value for key, value in road.items())), None)
            if same is not None and set(plan["removeIds"]) <= existing_removes:
                plan = dict(plan, manualRoadId=same["id"], alreadyApproved=True)
                already.append({
                    "street": street["name"], "streetIndex": street["streetIndex"],
                    "line": entry["line"], "manualRoadId": same["id"],
                    "removeIds": plan["removeIds"],
                })
                items.append(report_entry(entry, plan))
                continue
            if identity in existing_roads or set(plan["removeIds"]) & existing_removes:
                plan = {"feasible": False,
                        "blocker": "既有修補 ID 或移除段衝突，但幾何／完整操作不一致，需人工確認"}
        if not plan["feasible"]:
            manual.append({
                "street": street["name"],
                "streetIndex": street["streetIndex"],
                "line": entry["line"],
                "blocker": plan["blocker"],
                "raw": [list(point) for point in entry["raw"]],
                "new": [list(point) for point in entry["new"]],
            })
            items.append(report_entry(entry, plan))
            continue

        plan["manualRoadId"] = identity
        road.update(id=identity, reason=build_reason(entry, plan))
        new_roads.append(road)
        existing_roads[identity] = road
        existing_removes.update(plan["removeIds"])
        new_removes.extend(plan["removeIds"])
        items.append(report_entry(entry, plan))

    ext_overlap: list[dict] = []
    ext_streets: list[dict] = []
    if args.ext_lua:
        decided = {c["id"] for c in approvals["approvedCandidates"]}
        decided |= {c["id"] for c in approvals["rejectedCandidates"]}
        ext_streets = parse_ext_streets(ext_raw.decode("utf-8"))
        ext_overlap = overlap_ext_candidates(ext_streets, audit, decided)

    counts: dict[str, int] = {}
    for entry in active:
        counts[entry["klass"]] = counts.get(entry["klass"], 0) + 1

    report = {
        "schemaVersion": 1,
        "targetSrc": target_src,
        "streetsXmlSha256": xml_sha,
        "patchLuaSha256": hashlib.sha256(patch_raw).hexdigest(),
        "extLuaSha256": hashlib.sha256(ext_raw).hexdigest() if ext_raw is not None else None,
        "edgeTolerance": EDGE_TOL,
        "vertexTolerance": VERTEX_TOL,
        "counts": {
            "activePatches": len(active),
            "disabledPatches": len(disabled),
            "confirmed": counts.get("confirmed", 0),
            "cosmetic": counts.get("cosmetic", 0),
            "badFix": counts.get("bad-fix", 0),
            "ambiguous": counts.get("ambiguous", 0),
            "generatedManualRoads": len(new_roads),
            "generatedRemoves": len(new_removes),
            "manualFollowUp": len(manual),
            "alreadyApproved": len(already),
            "extStreets": len(ext_streets),
            "extCandidateOverlaps": len(ext_overlap),
        },
        "disabled": [
            {"line": entry["line"], "street": entry["street"],
             "raw": [list(p) for p in entry["raw"]], "new": [list(p) for p in entry["new"]]}
            for entry in disabled
        ],
        "patches": items,
        "generated": {"remove": sorted(new_removes), "manualRoads": new_roads},
        "manualFollowUp": manual,
        "alreadyApproved": already,
        "extCandidateOverlap": ext_overlap,
    }
    G.atomic_write(args.out, A.dumps_canonical(report))

    if args.emit_approvals:
        merged = dict(approvals)
        merged["remove"] = sorted(set(approvals["remove"]) | set(new_removes))
        merged["manualRoads"] = approvals["manualRoads"] + new_roads
        G.atomic_write(args.emit_approvals, json.dumps(merged, ensure_ascii=False, indent=2) + "\n")

    print(f"active patches      : {len(active)} (disabled/commented: {len(disabled)})")
    print(f"  confirmed         : {counts.get('confirmed', 0)}")
    print(f"  cosmetic          : {counts.get('cosmetic', 0)}")
    print(f"  bad-fix           : {counts.get('bad-fix', 0)}")
    print(f"  ambiguous         : {counts.get('ambiguous', 0)}")
    print(f"generated manualRoads: {len(new_roads)} (remove ids: {len(new_removes)})")
    for road in new_roads:
        print(f"  + {road['id']}: {len(road['points']) // 2} pts, "
              f"width {road['width']:g}, surface {road['surface']}")
    print(f"already in approvals : {len(already)}")
    for item in already:
        print(f"  = {item['manualRoadId']} ({item['street']})")
    print(f"manual follow-up    : {len(manual)}")
    for item in manual:
        print(f"  ! {item['street']} (streetIndex {item['streetIndex']}, "
              f"lua line {item['line']}): {item['blocker']}")
    print(f"ext streets         : {len(ext_streets)}")
    print(f"ext × audit overlap : {len(ext_overlap)}")
    print(f"report              : {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
