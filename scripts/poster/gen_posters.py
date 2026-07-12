from __future__ import annotations

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


WORK_SIZE = 1024
OUTPUT_SIZE = 512
ROOT = Path(__file__).resolve().parent
MASCOT_PATH = ROOT / "mascot.png"
OUTPUT_DIR = ROOT / "posters"
FONT_DIR = Path("C:/Windows/Fonts")

GOLD = (255, 214, 112, 255)
PALE_GOLD = (255, 239, 179, 255)
INK = (37, 27, 88, 255)
WHITE = (255, 251, 255, 255)


def font(size: int, *names: str) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for name in names:
        path = FONT_DIR / name
        if path.is_file():
            try:
                return ImageFont.truetype(str(path), size=size)
            except OSError:
                pass
    return ImageFont.load_default(size=size)


def fit_font(
    draw: ImageDraw.ImageDraw,
    text: str,
    max_width: int,
    start_size: int,
    minimum_size: int,
    *names: str,
) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for size in range(start_size, minimum_size - 1, -2):
        candidate = font(size, *names)
        box = draw.textbbox((0, 0), text, font=candidate, stroke_width=max(1, size // 28))
        if box[2] - box[0] <= max_width:
            return candidate
    return font(minimum_size, *names)


def vertical_gradient(top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    image = Image.new("RGBA", (WORK_SIZE, WORK_SIZE))
    draw = ImageDraw.Draw(image)
    for y in range(WORK_SIZE):
        t = y / (WORK_SIZE - 1)
        color = tuple(round(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,)
        draw.line((0, y, WORK_SIZE, y), fill=color)
    return image


def cover_square(source: Image.Image, size: int) -> Image.Image:
    scale = max(size / source.width, size / source.height)
    resized = source.resize(
        (round(source.width * scale), round(source.height * scale)),
        Image.Resampling.LANCZOS,
    )
    left = (resized.width - size) // 2
    top = (resized.height - size) // 2
    return resized.crop((left, top, left + size, top + size))


def ellipse_portrait(source: Image.Image, size: int, feather: int = 10) -> Image.Image:
    portrait = cover_square(source, size).convert("RGBA")
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).ellipse((feather, feather, size - feather, size - feather), fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(feather / 2))
    portrait.putalpha(mask)
    return portrait


def star_points(cx: int, cy: int, outer: int, inner: int, points: int = 4) -> list[tuple[float, float]]:
    result = []
    for index in range(points * 2):
        angle = -math.pi / 2 + index * math.pi / points
        radius = outer if index % 2 == 0 else inner
        result.append((cx + math.cos(angle) * radius, cy + math.sin(angle) * radius))
    return result


def add_fixed_sparkles(image: Image.Image, positions: tuple[tuple[int, int, int], ...]) -> None:
    layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for x, y, radius in positions:
        draw.polygon(star_points(x, y, radius, max(2, radius // 5)), fill=PALE_GOLD)
        draw.ellipse((x - 2, y - 2, x + 2, y + 2), fill=WHITE)
    image.alpha_composite(layer)


def add_shadowed_art(
    image: Image.Image,
    art: Image.Image,
    xy: tuple[int, int],
    blur: int = 20,
    offset: tuple[int, int] = (0, 16),
    opacity: int = 130,
) -> None:
    alpha = art.getchannel("A").point(lambda value: value * opacity // 255)
    shadow_alpha = Image.new("L", image.size, 0)
    shadow_alpha.paste(alpha, (xy[0] + offset[0], xy[1] + offset[1]))
    shadow = Image.new("RGBA", image.size, INK)
    shadow.putalpha(shadow_alpha.filter(ImageFilter.GaussianBlur(blur)))
    image.alpha_composite(shadow)
    left, top = max(0, -xy[0]), max(0, -xy[1])
    right = min(art.width, image.width - xy[0])
    bottom = min(art.height, image.height - xy[1])
    if right > left and bottom > top:
        image.alpha_composite(
            art.crop((left, top, right, bottom)),
            (max(0, xy[0]), max(0, xy[1])),
        )


def draw_stroked_text(
    draw: ImageDraw.ImageDraw,
    xy: tuple[int, int],
    text: str,
    text_font: ImageFont.FreeTypeFont | ImageFont.ImageFont,
    fill: tuple[int, int, int, int] = WHITE,
    stroke_fill: tuple[int, int, int, int] = INK,
    stroke_width: int = 6,
) -> None:
    draw.text(
        xy,
        text,
        font=text_font,
        fill=fill,
        stroke_width=stroke_width,
        stroke_fill=stroke_fill,
    )


def draw_main_poster(mascot: Image.Image) -> Image.Image:
    image = vertical_gradient((112, 111, 232), (65, 54, 156))

    grid = Image.new("RGBA", image.size, (0, 0, 0, 0))
    gd = ImageDraw.Draw(grid)
    for position in range(-64, WORK_SIZE + 128, 80):
        gd.line((position, 0, position - 260, WORK_SIZE), fill=(220, 215, 255, 38), width=2)
        gd.line((0, position, WORK_SIZE, position - 260), fill=(220, 215, 255, 32), width=2)
    radar_center = (692, 612)
    for radius, width, alpha in ((406, 8, 190), (320, 3, 110), (225, 3, 90)):
        gd.ellipse(
            (
                radar_center[0] - radius,
                radar_center[1] - radius,
                radar_center[0] + radius,
                radar_center[1] + radius,
            ),
            outline=(255, 222, 132, alpha),
            width=width,
        )
    gd.line((radar_center[0] - 420, radar_center[1], WORK_SIZE, radar_center[1]), fill=(255, 235, 179, 90), width=3)
    gd.line((radar_center[0], 176, radar_center[0], WORK_SIZE), fill=(255, 235, 179, 90), width=3)
    gd.arc((394, 314, 990, 910), 202, 324, fill=(255, 246, 208, 255), width=10)
    image.alpha_composite(grid)

    portrait = ellipse_portrait(mascot, 820, feather=12)
    add_shadowed_art(image, portrait, (282, 202), blur=24, offset=(0, 18), opacity=150)

    ring = Image.new("RGBA", image.size, (0, 0, 0, 0))
    rd = ImageDraw.Draw(ring)
    rd.ellipse((284, 204, 1098, 1018), outline=(255, 232, 164, 235), width=8)
    rd.ellipse((300, 220, 1082, 1002), outline=(255, 255, 255, 90), width=2)
    image.alpha_composite(ring)

    panel = Image.new("RGBA", image.size, (0, 0, 0, 0))
    pd = ImageDraw.Draw(panel)
    pd.rounded_rectangle((36, 56, 620, 392), radius=42, fill=(35, 24, 92, 218), outline=(255, 226, 143, 210), width=4)
    pd.rectangle((36, 312, 590, 392), fill=(81, 73, 184, 235))
    image.alpha_composite(panel)

    draw = ImageDraw.Draw(image)
    brand_font = fit_font(draw, "Minidoracat", 520, 74, 54, "segoeuib.ttf", "arialbd.ttf")
    title_font = fit_font(draw, "MiniMap", 520, 142, 96, "impact.ttf", "arialbd.ttf")
    subtitle_font = fit_font(draw, "for Build 42", 470, 54, 40, "segoeuib.ttf", "arialbd.ttf")
    draw_stroked_text(draw, (62, 72), "Minidoracat", brand_font, stroke_width=5)
    draw_stroked_text(draw, (60, 154), "MiniMap", title_font, fill=GOLD, stroke_width=7)
    draw.text((72, 323), "for Build 42", font=subtitle_font, fill=WHITE)

    pin = Image.new("RGBA", image.size, (0, 0, 0, 0))
    p = ImageDraw.Draw(pin)
    p.polygon(((848, 774), (916, 904), (984, 774)), fill=(255, 206, 92, 255), outline=WHITE)
    p.ellipse((848, 706, 984, 842), fill=(255, 213, 105, 255), outline=WHITE, width=8)
    p.ellipse((891, 749, 941, 799), fill=(73, 61, 167, 255))
    image.alpha_composite(pin)

    add_fixed_sparkles(image, ((72, 470, 19), (185, 894, 13), (894, 106, 18), (966, 522, 10)))
    return image


def map_card(angle: float, accent: tuple[int, int, int, int], label: str) -> Image.Image:
    card = Image.new("RGBA", (560, 390), (0, 0, 0, 0))
    draw = ImageDraw.Draw(card)
    draw.rounded_rectangle((12, 12, 548, 378), radius=34, fill=(249, 242, 255, 250), outline=accent, width=9)
    draw.rectangle((42, 46, 518, 332), fill=(225, 220, 248, 255), outline=(104, 89, 187, 255), width=4)
    for x in (102, 214, 366, 468):
        draw.line((x, 52, x - 42, 328), fill=(255, 255, 255, 210), width=15)
        draw.line((x, 52, x - 42, 328), fill=(128, 115, 204, 210), width=4)
    for y in (112, 196, 276):
        draw.line((48, y, 512, y + 22), fill=(255, 255, 255, 210), width=14)
        draw.line((48, y, 512, y + 22), fill=(128, 115, 204, 210), width=4)
    draw.rectangle((78, 78, 174, 152), fill=(176, 206, 176, 255))
    draw.rectangle((330, 216, 462, 302), fill=(181, 209, 188, 255))
    label_font = font(34, "arialbd.ttf", "segoeuib.ttf")
    draw.rounded_rectangle((54, 300, 260, 356), radius=22, fill=(48, 35, 106, 225))
    draw.text((76, 307), label, font=label_font, fill=WHITE)
    return card.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)


def draw_pin(draw: ImageDraw.ImageDraw, center: tuple[int, int], scale: int = 1) -> None:
    x, y = center
    radius = 40 * scale
    draw.polygon(((x - radius, y), (x, y + radius * 2), (x + radius, y)), fill=GOLD, outline=WHITE)
    draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=GOLD, outline=WHITE, width=5 * scale)
    draw.ellipse((x - 13 * scale, y - 13 * scale, x + 13 * scale, y + 13 * scale), fill=(72, 57, 157, 255))


def draw_maps_poster(mascot: Image.Image) -> Image.Image:
    image = vertical_gradient((55, 44, 137), (142, 91, 190))

    bounds = Image.new("RGBA", image.size, (0, 0, 0, 0))
    bd = ImageDraw.Draw(bounds)
    for inset, alpha in ((34, 150), (58, 70)):
        bd.rounded_rectangle(
            (inset, inset, WORK_SIZE - inset, WORK_SIZE - inset),
            radius=46,
            outline=(255, 222, 130, alpha),
            width=4,
        )
    bd.line((72, 468, 540, 468), fill=(255, 232, 164, 100), width=4)
    bd.line((304, 212, 304, 710), fill=(255, 232, 164, 70), width=4)
    image.alpha_composite(bounds)

    cards = (
        (map_card(-13, (255, 197, 91, 255), "MAP 01"), (-150, 188)),
        (map_card(8, (119, 101, 211, 255), "MAP 02"), (18, 112)),
        (map_card(-3, (255, 215, 112, 255), "MAP 03"), (130, 266)),
    )
    for card, xy in cards:
        add_shadowed_art(image, card, xy, blur=14, offset=(0, 14), opacity=100)

    portrait = ellipse_portrait(mascot, 610, feather=10)
    add_shadowed_art(image, portrait, (450, 40), blur=26, offset=(-8, 18), opacity=160)

    frame = Image.new("RGBA", image.size, (0, 0, 0, 0))
    fd = ImageDraw.Draw(frame)
    fd.ellipse((450, 40, 1060, 650), outline=GOLD, width=12)
    fd.ellipse((468, 58, 1042, 632), outline=(255, 255, 255, 110), width=3)
    draw_pin(fd, (167, 350))
    draw_pin(fd, (358, 242))
    image.alpha_composite(frame)

    title_panel = Image.new("RGBA", image.size, (0, 0, 0, 0))
    td = ImageDraw.Draw(title_panel)
    td.rounded_rectangle((34, 606, 990, 980), radius=52, fill=(31, 23, 82, 242), outline=GOLD, width=6)
    td.rounded_rectangle((56, 844, 968, 954), radius=34, fill=(100, 86, 201, 245))
    td.rounded_rectangle((48, 52, 300, 130), radius=34, fill=GOLD, outline=WHITE, width=4)
    image.alpha_composite(title_panel)

    draw = ImageDraw.Draw(image)
    badge_font = fit_font(draw, "ADD-ON", 210, 44, 34, "arialbd.ttf", "segoeuib.ttf")
    title_font = fit_font(draw, "MOD Maps", 880, 172, 110, "impact.ttf", "arialbd.ttf")
    subtitle_font = fit_font(draw, "MiniMap Map Pack", 820, 58, 42, "segoeuib.ttf", "arialbd.ttf")
    draw.text((79, 68), "ADD-ON", font=badge_font, fill=INK)
    draw_stroked_text(draw, (74, 640), "MOD Maps", title_font, fill=WHITE, stroke_fill=(74, 54, 153, 255), stroke_width=8)
    subtitle_box = draw.textbbox((0, 0), "MiniMap Map Pack", font=subtitle_font)
    subtitle_width = subtitle_box[2] - subtitle_box[0]
    draw.text(((WORK_SIZE - subtitle_width) // 2, 866), "MiniMap Map Pack", font=subtitle_font, fill=PALE_GOLD)

    add_fixed_sparkles(image, ((372, 78, 14), (918, 706, 18), (84, 570, 12), (962, 164, 10)))
    return image


def save_pair(image: Image.Image, poster_name: str, preview_name: str) -> None:
    final = image.convert("RGB").resize((OUTPUT_SIZE, OUTPUT_SIZE), Image.Resampling.LANCZOS)
    final.save(OUTPUT_DIR / poster_name, format="PNG", optimize=False, compress_level=9)
    final.save(OUTPUT_DIR / preview_name, format="PNG", optimize=False, compress_level=9)


def main() -> None:
    if not MASCOT_PATH.is_file():
        raise FileNotFoundError(f"Mascot image not found: {MASCOT_PATH}")

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    with Image.open(MASCOT_PATH) as source:
        mascot = source.convert("RGBA")

    save_pair(draw_main_poster(mascot), "main_poster.png", "main_preview.png")
    save_pair(draw_maps_poster(mascot), "maps_poster.png", "maps_preview.png")


if __name__ == "__main__":
    main()
