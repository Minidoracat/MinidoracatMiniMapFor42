# 視野扇形貼圖 media/ui/minimap_facing_cone.png（_Nav.lua Core.drawFacingConeQuad）：
# 128×128 白色，形狀只放在 alpha，畫的時候再上色。u（x）沿前方：0＝頂點、1＝長度 L；
# v（y）沿側邊：±FACING_CONE_SIDE·L。頂點在左邊中間。半角或 SIDE 改了要同步 _Nav.lua 的 FACING_CONE_SIDE。
# 用法：uv run --with pillow scripts/make_facing_cone.py
import math
import os

from PIL import Image

HALF = math.radians(38)
SIDE = math.sin(HALF) * 1.02  # 側邊範圍剛好包住扇形的弧（_Nav.lua FACING_CONE_SIDE＝0.628）
SIZE = 128
PEAK = 0.62                   # 頂點附近的最大不透明度
OUT = os.path.join(os.path.dirname(__file__), "..", "MOD", "MinidoracatMiniMapFor42", "Contents", "mods",
                   "MinidoracatMiniMapFor42", "42", "media", "ui", "minimap_facing_cone.png")


def alpha(fx, sy):
    r = math.hypot(fx, sy)
    th = abs(math.atan2(sy, fx))
    if r >= 1 or th >= HALF:
        return 0
    radial = (1 - r) ** 1.35                          # 越遠越淡
    edge = min(1.0, (HALF - th) / math.radians(9))    # 兩側 9° 內淡出
    edge = edge * edge * (3 - 2 * edge)
    near = min(1.0, r / 0.08)                         # 頂點 8% 內淡出，不蓋住箭頭尖
    return round(PEAK * radial * edge * near * 255)


img = Image.new("RGBA", (SIZE, SIZE))
px = img.load()
for y in range(SIZE):
    for x in range(SIZE):
        px[x, y] = (255, 255, 255, alpha((x + 0.5) / SIZE, ((y + 0.5) / SIZE * 2 - 1) * SIDE))
img.save(os.path.normpath(OUT), optimize=True)
print(os.path.normpath(OUT))
