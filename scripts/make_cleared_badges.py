# 資源點「去過／已清空」角標 media/ui/minimap_badge_{visited,cleared,refreshed}.png（_ClearedUI.lua clearedBadge）：
# 24×24，白色形狀＋深色描邊（繪製時乘上顏色：白點、白勾或隊友青勾、綠三角；描邊乘完仍是深色，淺色地圖上也看得到）。
# 地圖上畫成 6–12 px，所以形狀要粗。先畫 8 倍大再縮小，邊緣反鋸齒。程式產生、MIT（42/LICENSE.txt 第 1 節）。
# 用法：uv run --with pillow scripts/make_cleared_badges.py
import os

from PIL import Image, ImageDraw

SIZE, SS = 24, 8
OUT = os.path.join(os.path.dirname(__file__), "..", "MOD", "MinidoracatMiniMapFor42", "Contents", "mods",
                   "MinidoracatMiniMapFor42", "42", "media", "ui")
EDGE = (20, 20, 20, 255)
FILL = (255, 255, 255, 255)


def s(v):
    return v * SS


def dot(d, w):
    d.ellipse([s(3), s(3), s(21), s(21)], fill=EDGE)
    d.ellipse([s(3 + w), s(3 + w), s(21 - w), s(21 - w)], fill=FILL)


def check(d, w):
    pts = [(s(3.5), s(12.5)), (s(9.5), s(18.5)), (s(20.5), s(5.5))]
    d.line(pts, fill=EDGE, width=s(7), joint="curve")
    for p in (pts[0], pts[2]):
        d.ellipse([p[0] - s(3.5), p[1] - s(3.5), p[0] + s(3.5), p[1] + s(3.5)], fill=EDGE)
    d.line(pts, fill=FILL, width=s(7 - 2 * w), joint="curve")
    for p in (pts[0], pts[2]):
        r = s(3.5 - w)
        d.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=FILL)


def triangle(d, w):
    d.polygon([(s(12), s(1.5)), (s(23), s(21.5)), (s(1), s(21.5))], fill=EDGE)
    d.polygon([(s(12), s(1.5 + w * 2.2)), (s(23 - w * 1.9), s(21.5 - w)), (s(1 + w * 1.9), s(21.5 - w))], fill=FILL)


for name, fn in (("visited", dot), ("cleared", check), ("refreshed", triangle)):
    big = Image.new("RGBA", (s(SIZE), s(SIZE)), (0, 0, 0, 0))
    fn(ImageDraw.Draw(big), 2)
    img = big.resize((SIZE, SIZE), Image.LANCZOS)
    path = os.path.normpath(os.path.join(OUT, f"minimap_badge_{name}.png"))
    img.save(path, optimize=True)
    print(path)
