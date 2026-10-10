#!/usr/bin/env python3
"""Bake the parking-lot layer into MinidoracatMiniMapParkingData.lua.

Source: the map's ParkingStall vehicle zones (objects.lua), the spots where the
engine spawns parked cars. A parking lot is a group of those zones; single
spots are almost always home driveways. The rules below were checked against
in-game screenshots of 1,294 vanilla candidates and 171 Frogtown / Daisy County
candidates (2026-10-10, report https://share.onorca.dev/a/sOx1QlNzxxpu):

1. rows   -- stall zones 2 tiles or less apart (traffic jams, junkyards, farms,
             burnt wrecks and the McCoy yard are not parking: NOT_PARKING).
2. areas  -- rows that hold 2+ cars, merged when 8 tiles or less apart (the
             aisles of a lot are 6-8 tiles wide). Capacity = area / 15 squares.
3. keep   -- painted parking lines (street_trafficlines_01_*) OR 6+ cars, and
             under half of the stall squares on grass, and (vanilla only) under
             half of them within 2 tiles of a worldmap.xml road: those rows are
             curbside parking. Map mods paint their lots as road in worldmap.xml,
             so they skip the road test (80 of 92 Frogtown/Daisy lots sat inside
             road shapes).
4. lots   -- kept areas 20 tiles or less apart with no road between them form
             one lot (vanilla only); one area per lot -- the one nearest the
             capacity-weighted centre -- carries the lot's P icon and search hit.

Stripes and floor tiles come from the lotpacks via MapRendering
(`pzmap stall-tiles`). The map pack bakes its maps with bake() too
(MinidoracatMiniMapModMapsFor42 scripts/gen_map_resources.py).

Usage:
    python scripts/gen_parking_data.py [--vanilla-maps DIR] [--pzmap EXE] [--out PATH]
"""
import argparse
import os
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SHARED_LUA_DIR = (
    REPO_ROOT
    / "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42"
    / "42/media/lua/shared"
)
DEFAULT_OUT = SHARED_LUA_DIR / "MinidoracatMiniMapParkingData.lua"
PZ_PATH = Path(os.environ.get("PZ_PATH", r"D:\SteamLibrary\steamapps\common\ProjectZomboid"))
DEFAULT_VANILLA_MAPS = PZ_PATH / "media" / "maps" / "Muldraugh, KY"
DEFAULT_PZMAP = Path(os.environ.get(
    "PZMAP", REPO_ROOT.parent / "MinidoracatMapRendering" / "target" / "release" / "pzmap.exe"))

NOT_PARKING = re.compile(r"^(r?trafficjam[nsew]|junkyard|farm|burnt|mccoy)$", re.IGNORECASE)
ROW_GAP = 2           # 同一排：車位區相距 ≤2 格
AREA_GAP = 8          # 同一區：排與排相距 ≤8 格（走道寬）
LOT_GAP = 20          # 同一座：區與區相距 ≤20 格且中間沒有道路（只用在原版）
SQUARES_PER_CAR = 15  # 一台車約 3×5 格
MIN_CARS = 2          # 單一車位幾乎都是住家車道
PLAIN_MIN_CARS = 6    # 沒有停車格線時，至少能停幾台才標成停車場
ROAD_NEAR = 2         # 車位在道路幾格內算「貼著道路」
ROAD_KINDS = ("primary", "secondary", "tertiary")
STRIPE_PREFIX = "street_trafficlines_01_"

_FIELD_RE = re.compile(r'\b(name|type|x|y|z|width|height)\s*=\s*(?:"([^"]*)"|(-?\d+))')


def parse_stalls(objects_lua_text):
    """ParkingStall zones at level 0 that can hold parked cars: [(x, y, w, h), ...] sorted."""
    out = []
    for line in objects_lua_text.splitlines():
        if '"ParkingStall"' not in line:
            continue
        # findall 對沒對到的群組回空字串：數字欄位走 n，字串欄位（name = "" 也算）走 s
        f = {k: (int(n) if n else s) for k, s, n in _FIELD_RE.findall(line)}
        if f.get("type") != "ParkingStall" or f.get("z", 0) != 0 or NOT_PARKING.match(f.get("name", "")):
            continue
        if f.get("width", 0) > 0 and f.get("height", 0) > 0:
            out.append((f["x"], f["y"], f["width"], f["height"]))
    return sorted(out)


def box_gap(a, b):
    """Gap in tiles between two boxes (x1, y1, x2, y2), inclusive; 0 = touching or overlapping."""
    gx = max(0, max(a[0], b[0]) - min(a[2], b[2]) - 1)
    gy = max(0, max(a[1], b[1]) - min(a[3], b[3]) - 1)
    return max(gx, gy)


def _box(rects):
    return (min(r[0] for r in rects), min(r[1] for r in rects),
            max(r[0] + r[2] - 1 for r in rects), max(r[1] + r[3] - 1 for r in rects))


def _cluster(items, boxes, gap, linked=None):
    """Union-find over items whose boxes are `gap` tiles or less apart (and linked(a, b) if given)."""
    parent = list(range(len(items)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    cell = 64
    grid = {}
    for i, b in enumerate(boxes):
        for gx in range((b[0] - gap) // cell, (b[2] + gap) // cell + 1):
            for gy in range((b[1] - gap) // cell, (b[3] + gap) // cell + 1):
                grid.setdefault((gx, gy), []).append(i)
    for members in grid.values():
        for ai in range(len(members)):
            for bi in range(ai + 1, len(members)):
                a, b = members[ai], members[bi]
                if find(a) != find(b) and box_gap(boxes[a], boxes[b]) <= gap \
                        and (linked is None or linked(a, b)):
                    parent[find(a)] = find(b)
    groups = {}
    for i in range(len(items)):
        groups.setdefault(find(i), []).append(items[i])
    return list(groups.values())


def cars(rect):
    return round(rect[2] * rect[3] / SQUARES_PER_CAR)


def coalesce(rects):
    """Join touching stalls of one row: same y/h side by side, then same x/w end to end. Same squares, fewer rects."""
    out = []
    for r in sorted(rects, key=lambda r: (r[1], r[3], r[0])):
        p = out[-1] if out else None
        if p and p[1] == r[1] and p[3] == r[3] and p[0] + p[2] == r[0]:
            out[-1] = (p[0], p[1], p[2] + r[2], p[3])
        else:
            out.append(r)
    rows, out = out, []
    for r in sorted(rows, key=lambda r: (r[0], r[2], r[1])):
        p = out[-1] if out else None
        if p and p[0] == r[0] and p[2] == r[2] and p[1] + p[3] == r[1]:
            out[-1] = (p[0], p[1], p[2], p[3] + r[3])
        else:
            out.append(r)
    return sorted(out)


def group_areas(stalls):
    """Rows of zones, then areas of rows that hold MIN_CARS+ cars: [{rects, box, cap}], sorted by box.
    Capacity counts every zone on its own (a 3x5 stall holds one car); rects are coalesced afterwards."""
    rows = _cluster(stalls, [_box([s]) for s in stalls], ROW_GAP)
    rows = [r for r in rows if sum(cars(s) for s in r) >= MIN_CARS]
    areas = []
    for members in _cluster(rows, [_box(r) for r in rows], AREA_GAP):
        zones = [s for row in members for s in row]
        rects = coalesce(zones)
        areas.append({"rects": rects, "box": _box(rects), "cap": sum(cars(s) for s in zones)})
    return sorted(areas, key=lambda a: (a["box"], a["rects"]))


def stall_tiles(pzmap, map_dir, areas):
    """`pzmap stall-tiles` for every area: {area index: (squares, {stripe: n}, {floor class: n})}."""
    def kv(text):
        return {k: int(v) for k, _, v in (p.rpartition("=") for p in text.split(";") if p)}

    with tempfile.TemporaryDirectory() as tmp:
        units, out = Path(tmp) / "units.tsv", Path(tmp) / "tiles.tsv"
        units.write_text("".join(f"S {i} {x} {y} {w} {h}\n" for i, a in enumerate(areas)
                                 for x, y, w, h in a["rects"]), encoding="utf-8")
        r = subprocess.run([str(pzmap), "stall-tiles", "--maps-dir", str(map_dir), "--units", str(units),
                            "--out", str(out)], capture_output=True, text=True, encoding="utf-8", errors="replace")
        if r.returncode != 0:
            raise SystemExit(f"pzmap stall-tiles failed ({map_dir}): {(r.stderr or r.stdout).strip()[-300:]}")
        tiles = {}
        for line in out.read_text(encoding="utf-8").splitlines():
            uid, squares, stripes, floors = (line.split("\t") + ["", "", ""])[:4]
            tiles[int(uid)] = (int(squares), kv(stripes), kv(floors))
    return tiles


def road_squares(worldmap_xml):
    """Squares inside the primary/secondary/tertiary road shapes of a worldmap.xml (filled like PIL does)."""
    from PIL import Image, ImageDraw  # 只有原版烘焙用得到

    road = set()
    for c in ET.parse(worldmap_xml).getroot().iter("cell"):
        img, hit = Image.new("1", (300, 300), 0), False
        draw = ImageDraw.Draw(img)
        for feat in c.iter("feature"):
            kind = {p.get("name"): p.get("value") for p in feat.iter("property")}.get("highway")
            if kind not in ROAD_KINDS:
                continue
            for coords in feat.iter("coordinates"):
                pts = [(int(p.get("x")), int(p.get("y"))) for p in coords.iter("point")]
                if len(pts) >= 3:
                    draw.polygon(pts, fill=1)
                    hit = True
        if hit:
            ox, oy, px = int(c.get("x")) * 300, int(c.get("y")) * 300, img.load()
            road.update((ox + x, oy + y) for y in range(300) for x in range(300) if px[x, y])
    return road


def near_road_share(rects, road, d=ROAD_NEAR):
    squares = [(x, y) for rx, ry, rw, rh in rects for x in range(rx, rx + rw) for y in range(ry, ry + rh)]
    near = sum(1 for x, y in squares
               if any((x + i, y + j) in road for i in range(-d, d + 1) for j in range(-d, d + 1)))
    return near / len(squares)


def is_parking(area, stripes, floors, road=None):
    """Rule 3 of the module docstring. road=None skips the curbside test (map mods)."""
    if area["cap"] < MIN_CARS or not (stripes or area["cap"] >= PLAIN_MIN_CARS):
        return False
    if floors.get("natural", 0) * 2 >= max(1, sum(floors.values())):
        return False
    return road is None or near_road_share(area["rects"], road) < 0.5


def _road_between(a, b, road):
    """Any road square in the band between two boxes (the overlap span on one axis, the gap on the other)."""
    def span(lo1, hi1, lo2, hi2):
        lo, hi = max(lo1, lo2), min(hi1, hi2)
        return (lo, hi) if lo <= hi else (hi, lo)

    x0, x1 = span(a[0], a[2], b[0], b[2])
    y0, y1 = span(a[1], a[3], b[1], b[3])
    return any((x, y) in road for x in range(x0, x1 + 1) for y in range(y0, y1 + 1))


def mark_lots(areas, road=None):
    """Rule 4: set area["icon"] = True on one area per lot; returns the lot count.
    Without road data every area is its own lot."""
    if road is None:
        for a in areas:
            a["icon"] = True
        return len(areas)
    boxes = [a["box"] for a in areas]
    lots = _cluster(list(range(len(areas))), boxes, LOT_GAP,
                    lambda i, j: not _road_between(boxes[i], boxes[j], road))
    for members in lots:
        group = [areas[i] for i in members]
        total = sum(a["cap"] for a in group)

        def centre(a):
            return (a["box"][0] + a["box"][2] + 1) / 2, (a["box"][1] + a["box"][3] + 1) / 2

        wx = sum(centre(a)[0] * a["cap"] for a in group) / total
        wy = sum(centre(a)[1] * a["cap"] for a in group) / total
        best = min(group, key=lambda a: ((centre(a)[0] - wx) ** 2 + (centre(a)[1] - wy) ** 2, a["box"]))
        for a in group:
            a["icon"] = a is best
    return len(lots)


def bake(map_dir, pzmap=DEFAULT_PZMAP, use_roads=True):
    """Parking areas of one map directory: (entries, stats). entries are areas with rects/box/cap/icon."""
    map_dir = Path(map_dir)
    objects = map_dir / "objects.lua"
    stats = {"stalls": 0, "areas": 0, "rule": 0, "road": 0, "grass": 0, "kept": 0, "lots": 0}
    if not objects.is_file():
        return [], stats
    stalls = parse_stalls(objects.read_text(encoding="utf-8", errors="replace"))
    areas = group_areas(stalls)
    stats["stalls"], stats["areas"] = len(stalls), len(areas)
    if not areas:
        return [], stats
    tiles = stall_tiles(pzmap, map_dir, areas)
    worldmap = map_dir / "worldmap.xml"
    road = road_squares(worldmap) if use_roads and worldmap.is_file() else None
    kept = []
    for i, a in enumerate(areas):
        _, stripes, floors = tiles.get(i, (0, {}, {}))
        if not (stripes or a["cap"] >= PLAIN_MIN_CARS):
            continue
        stats["rule"] += 1
        if floors.get("natural", 0) * 2 >= max(1, sum(floors.values())):
            stats["grass"] += 1
        elif road is not None and near_road_share(a["rects"], road) >= 0.5:
            stats["road"] += 1
        else:
            kept.append(a)
    stats["kept"] = len(kept)
    stats["lots"] = mark_lots(kept, road)
    return kept, stats


def render_entry(a):
    """One area as a Lua table constructor (contract in render_lua). The map pack uses it too."""
    rects = ", ".join(f"{{ x = {x}, y = {y}, w = {w}, h = {h} }}" for x, y, w, h in a["rects"])
    x1, y1, x2, y2 = a["box"]
    icon = ", i = 1" if a.get("icon") else ""
    return (f"{{ rn = {len(a['rects'])}, r = {{ {rects} }}, "
            f"b = {{ x = {x1}, y = {y1}, w = {x2 - x1 + 1}, h = {y2 - y1 + 1} }}{icon} }}")


def render_lua(entries, stats, gen_command):
    lines = [
        "-- MinidoracatMiniMapParkingData.lua",
        "-- 由 scripts/gen_parking_data.py 產生，請勿手動編輯。重新產生：",
        f"--   {gen_command}",
        "--",
        f"-- 來源：原版 objects.lua 的 ParkingStall 車輛生成區 {stats['stalls']} 個 → {stats['areas']} 區能停 2 台以上；",
        f"-- 有停車格線或能停 6 台以上 {stats['rule']} 區，排除貼路 {stats['road']}、草地 {stats['grass']}，"
        f"留下 {stats['kept']} 區、{stats['lots']} 座停車場。判定規則見產生器檔頭。",
        "-- 消費契約（MinidoracatMiniMapResources.lua parkingEntries、MinidoracatMiniMapParking.lua）：",
        "-- 陣列，每項一區 { rn=<排數>, r={ {x,y,w,h},.. }, b={x,y,w,h}, i=1|nil }（世界 square 座標、地面層）；",
        "-- r＝車位排，b＝整區外框（含全部 r），i=1＝這區帶整座停車場的 P 圖示與搜尋結果，每座恰一區。",
        "-- 迭代一律用 rn（Kahlua # 不可信）；count 為除錯輔助欄位。地圖優先序沿用 MinidoracatMiniMapPOIData 的 cells300。",
        "",
        "MinidoracatMiniMapParkingData = {",
    ]
    lines += [f"    {render_entry(a)}," for a in entries]
    lines += ["}", "", f"MinidoracatMiniMapParkingData.count = {len(entries)}", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--vanilla-maps", type=Path, default=DEFAULT_VANILLA_MAPS,
                        help="vanilla map directory (objects.lua, worldmap.xml, lotheaders, lotpacks)")
    parser.add_argument("--pzmap", type=Path, default=DEFAULT_PZMAP, help="MapRendering pzmap executable")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="output .lua path")
    args = parser.parse_args()
    if not (args.vanilla_maps / "objects.lua").is_file():
        parser.error(f"objects.lua not found in {args.vanilla_maps}; set PZ_PATH or pass --vanilla-maps")
    if not args.pzmap.is_file():
        parser.error(f"pzmap not found: {args.pzmap}; build MapRendering (cargo build --release) or pass --pzmap")

    entries, stats = bake(args.vanilla_maps, args.pzmap, use_roads=True)
    text = render_lua(entries, stats, "python scripts/gen_parking_data.py")
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    print(f"stall zones:              {stats['stalls']}")
    print(f"areas with 2+ cars:       {stats['areas']}")
    print(f"striped or 6+ cars:       {stats['rule']}  (dropped: near a road {stats['road']}, on grass {stats['grass']})")
    print(f"kept:                     {stats['kept']} areas -> {stats['lots']} lots (one P each)")
    print(f"output:                   {args.out}")


if __name__ == "__main__":
    main()
