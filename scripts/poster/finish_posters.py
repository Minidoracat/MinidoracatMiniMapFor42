# -*- coding: utf-8 -*-
"""把 codex imagegen 主視覺疊上 PZ 風標題，輸出正式 poster 四檔（512×512）。
Deterministic：無隨機數。"""
import os
from PIL import Image, ImageDraw, ImageFont

SP = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(SP, "posters")
os.makedirs(OUT, exist_ok=True)

FONTS = r"C:/Windows/Fonts"
GOLD = (233, 195, 90, 255)
PALE = (240, 234, 214, 255)
INK = (28, 26, 20, 255)
BOARD = (38, 40, 30, 235)      # 暗橄欖告示板
BOARD_EDGE = (18, 18, 12, 255)
TAPE = (214, 200, 160, 210)    # 泛黃膠帶
HAZ_Y = (208, 168, 40, 255)    # 警戒黃
HAZ_K = (24, 22, 18, 255)      # 警戒黑


def font(size, *names):
    for n in names:
        p = os.path.join(FONTS, n)
        if os.path.isfile(p):
            return ImageFont.truetype(p, size)
    return ImageFont.load_default()


def fit(draw, text, max_w, size, *names):
    f = font(size, *names)
    while size > 12 and draw.textlength(text, font=f) > max_w:
        size -= 2
        f = font(size, *names)
    return f


def stroked(draw, xy, text, f, fill, stroke, w):
    draw.text(xy, text, font=f, fill=fill, stroke_width=w, stroke_fill=stroke)


def tape(draw, cx, cy, w=64, h=26, rot=0):
    # 簡化膠帶：中心矩形（不旋轉版，rot 僅微調位置感）
    draw.rectangle([cx - w // 2, cy - h // 2, cx + w // 2, cy + h // 2], fill=TAPE)


def hazard_strip(draw, x0, y0, x1, y1, step=26):
    draw.rectangle([x0, y0, x1, y1], fill=HAZ_Y)
    for s in range(x0 - (y1 - y0), x1, step * 2):
        draw.polygon([(s, y1), (s + step, y1), (s + step + (y1 - y0), y0), (s + (y1 - y0), y0)], fill=HAZ_K)
    draw.rectangle([x0, y0, x1, y1], outline=BOARD_EDGE, width=3)


def load_art(name):
    im = Image.open(os.path.join(SP, name)).convert("RGBA")
    if im.size != (1024, 1024):
        im = im.resize((1024, 1024), Image.LANCZOS)
    return im


def main_poster():
    im = load_art("main_art.png")
    d = ImageDraw.Draw(im)
    # 標題板：頂部偏左（右側留給耳朵/夜空），板 + 邊框 + 膠帶四角
    bx0, by0, bx1, by1 = 28, 26, 636, 232
    d.rectangle([bx0 + 6, by0 + 8, bx1 + 6, by1 + 8], fill=(0, 0, 0, 120))  # 投影
    d.rectangle([bx0, by0, bx1, by1], fill=BOARD, outline=BOARD_EDGE, width=4)
    hazard_strip(d, bx0, by0, bx1, by0 + 14)
    tape(d, bx0 + 26, by0 + 10)
    tape(d, bx1 - 26, by0 + 10)
    # 文字
    f_brand = fit(d, "Minidoracat", bx1 - bx0 - 60, 54, "segoeuib.ttf", "arialbd.ttf")
    f_title = fit(d, "MINIMAP", bx1 - bx0 - 56, 106, "impact.ttf", "arialbd.ttf")
    stroked(d, (bx0 + 30, by0 + 30), "Minidoracat", f_brand, PALE, INK, 3)
    stroked(d, (bx0 + 28, by0 + 88), "MINIMAP", f_title, GOLD, INK, 5)
    # for Build 42 小板
    f_sub = font(38, "segoeuib.ttf", "arialbd.ttf")
    sw = d.textlength("for Build 42", font=f_sub)
    d.rectangle([bx0, by1 + 10, bx0 + sw + 44, by1 + 66], fill=(52, 46, 34, 225), outline=BOARD_EDGE, width=3)
    stroked(d, (bx0 + 22, by1 + 16), "for Build 42", f_sub, PALE, INK, 2)
    return im


def maps_poster():
    im = load_art("maps_art.png")
    d = ImageDraw.Draw(im)
    # 標題板：底部整寬（暗地板區）
    bx0, by0, bx1, by1 = 26, 796, 998, 996
    d.rectangle([bx0 + 6, by0 + 8, bx1 + 6, by1 + 8], fill=(0, 0, 0, 130))
    d.rectangle([bx0, by0, bx1, by1], fill=BOARD, outline=BOARD_EDGE, width=4)
    hazard_strip(d, bx0, by1 - 14, bx1, by1)
    # 主標
    f_title = fit(d, "MOD MAPS", bx1 - bx0 - 320, 118, "impact.ttf", "arialbd.ttf")
    stroked(d, (bx0 + 36, by0 + 22), "MOD MAPS", f_title, PALE, (60, 44, 20, 255), 6)
    # 副標小板（右側）
    f_sub = font(40, "segoeuib.ttf", "arialbd.ttf")
    sub = "MiniMap Map Pack"
    sw = d.textlength(sub, font=f_sub)
    sx1 = bx1 - 24
    sx0 = sx1 - sw - 40
    d.rectangle([sx0, by1 - 84, sx1, by1 - 26], fill=(52, 46, 34, 230), outline=BOARD_EDGE, width=3)
    stroked(d, (sx0 + 20, by1 - 78), sub, f_sub, GOLD, INK, 2)
    # ADD-ON 斜角警示標籤（疊在標題板左上角）
    f_badge = font(42, "arialbd.ttf", "segoeuib.ttf")
    bw = d.textlength("ADD-ON", font=f_badge)
    ax0, ay0 = bx0 + 14, by0 - 34
    d.rectangle([ax0, ay0, ax0 + bw + 48, ay0 + 62], fill=HAZ_Y, outline=BOARD_EDGE, width=4)
    for s in range(int(ax0) - 60, int(ax0 + bw + 48), 30):  # 邊角斜紋
        d.polygon([(s, ay0 + 62), (s + 12, ay0 + 62), (s + 24, ay0), (s + 12, ay0)],
                  fill=HAZ_K if (s // 30) % 2 == 0 else HAZ_Y)
    d.rectangle([ax0 + 34, ay0 + 6, ax0 + bw + 14, ay0 + 56], fill=HAZ_Y)
    stroked(d, (ax0 + 38, ay0 + 8), "ADD-ON", f_badge, HAZ_K, HAZ_Y, 1)
    return im


def save(im, *names):
    small = im.resize((512, 512), Image.LANCZOS).convert("RGB")
    for n in names:
        small.save(os.path.join(OUT, n), "PNG")
        print("寫出:", n)


save(main_poster(), "main_poster.png", "main_preview.png")
save(maps_poster(), "maps_poster.png", "maps_preview.png")
print("done")
