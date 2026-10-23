# 設定視窗「自訂道路」分類圖示 media/ui/minimap_road.png（_Settings.lua MapRows.ROADS.iconTex）：
# 32×32 白色、形狀只放在 alpha（NavList 以原色 16 px 畫 Texture，不染色）。透視道路：實心梯形路面
# （和側欄其他實心圖示一致），頂部要寬而平，中線一段段挖空、越遠越短。2026-10-24 E2E road-style-sp
# 看 16 px 側欄淘汰過兩版：只畫兩條路邊的線條版像「/!\」警告符號；頂部收窄的實心版像粗體「A」。
# 斜放的平行路面放大看像 OK 繃，也不用。先畫 8 倍大再縮小，邊緣反鋸齒。
# 用法：uv run --with pillow scripts/make_road_icon.py
import os

from PIL import Image, ImageDraw

SIZE = 32
SS = 8  # 超取樣倍數
OUT = os.path.join(os.path.dirname(__file__), "..", "MOD", "MinidoracatMiniMapFor42", "Contents", "mods",
                   "MinidoracatMiniMapFor42", "42", "media", "ui", "minimap_road.png")

# 路面梯形：底 y＝31 的左右 x、頂 y＝1 的左右 x（頂寬約底寬一半，不收成尖頂）
BOTTOM, TOP = (1.0, 31.0), (8.5, 23.5)
# 挖空的中線各段：(下緣 y, 上緣 y, 半寬)，越遠越短、越細
DASHES = ((29.5, 22.5, 1.7), (18.5, 12.5, 1.45), (9.0, 3.5, 1.2))


def s(v):
    return v * SS


big = Image.new("L", (SIZE * SS, SIZE * SS), 0)
d = ImageDraw.Draw(big)
d.polygon([(s(BOTTOM[0]), s(31)), (s(BOTTOM[1]), s(31)), (s(TOP[1]), s(1)), (s(TOP[0]), s(1))], fill=255)
for y1, y2, hw in DASHES:
    d.polygon([(s(16 - hw), s(y1)), (s(16 + hw), s(y1)), (s(16 + hw * 0.9), s(y2)), (s(16 - hw * 0.9), s(y2))],
              fill=0)
alpha = big.resize((SIZE, SIZE), Image.LANCZOS)
img = Image.new("RGBA", (SIZE, SIZE), (255, 255, 255, 0))
img.putalpha(alpha)
img.save(os.path.normpath(OUT), optimize=True)
print(os.path.normpath(OUT))
