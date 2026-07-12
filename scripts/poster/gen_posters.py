from __future__ import annotations

import math
import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


WORK_SIZE = 1024
OUTPUT_SIZE = 512
ROOT = Path(__file__).resolve().parent
MASCOT_PATH = ROOT / "mascot.png"
OUTPUT_DIR = ROOT / "posters"
FONT_DIR = Path("C:/Windows/Fonts")

PAPER = (218, 199, 151, 255)
PALE_PAPER = (238, 222, 177, 255)
INK = (43, 42, 31, 255)
DARK_GREEN = (42, 52, 38, 255)
MILITIA_GREEN = (67, 76, 52, 255)
BLOOD = (102, 38, 29, 210)
GOLD = (218, 170, 57, 255)
PURPLE = (91, 75, 153, 255)


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


def composite_at(canvas: Image.Image, art: Image.Image, xy: tuple[int, int]) -> None:
    left = max(0, -xy[0])
    top = max(0, -xy[1])
    right = min(art.width, canvas.width - xy[0])
    bottom = min(art.height, canvas.height - xy[1])
    if right > left and bottom > top:
        canvas.alpha_composite(art.crop((left, top, right, bottom)), (max(0, xy[0]), max(0, xy[1])))


def add_shadowed_art(
    canvas: Image.Image,
    art: Image.Image,
    xy: tuple[int, int],
    blur: int = 16,
    offset: tuple[int, int] = (8, 14),
    opacity: int = 125,
) -> None:
    alpha = art.getchannel("A").point(lambda value: value * opacity // 255)
    shadow_alpha = Image.new("L", canvas.size, 0)
    shadow_alpha.paste(alpha, (xy[0] + offset[0], xy[1] + offset[1]))
    shadow = Image.new("RGBA", canvas.size, (15, 12, 8, 255))
    shadow.putalpha(shadow_alpha.filter(ImageFilter.GaussianBlur(blur)))
    canvas.alpha_composite(shadow)
    composite_at(canvas, art, xy)


def rotate_art(art: Image.Image, angle: float) -> Image.Image:
    return art.rotate(angle, resample=Image.Resampling.BICUBIC, expand=True)


def torn_mask(size: tuple[int, int], seed: int, step: int = 24, bite: int = 11) -> Image.Image:
    width, height = size
    rng = random.Random(seed)
    points: list[tuple[int, int]] = []
    for x in range(0, width + 1, step):
        points.append((min(x, width), rng.randint(0, bite)))
    for y in range(step, height + 1, step):
        points.append((width - rng.randint(0, bite), min(y, height)))
    for x in range(width - step, -1, -step):
        points.append((max(x, 0), height - rng.randint(0, bite)))
    for y in range(height - step, 0, -step):
        points.append((rng.randint(0, bite), y))
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    return mask


def textured_surface(
    size: tuple[int, int],
    base: tuple[int, int, int, int],
    seed: int,
    specks: int,
) -> Image.Image:
    image = Image.new("RGBA", size, base)
    draw = ImageDraw.Draw(image)
    rng = random.Random(seed)
    for _ in range(specks):
        x = rng.randrange(size[0])
        y = rng.randrange(size[1])
        radius = rng.choice((1, 1, 2, 3))
        delta = rng.randint(-24, 18)
        color = tuple(max(0, min(255, channel + delta)) for channel in base[:3]) + (rng.randint(18, 62),)
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color)
    for _ in range(34):
        x = rng.randrange(size[0])
        y = rng.randrange(size[1])
        length = rng.randint(18, 90)
        draw.line((x, y, x + length, y + rng.randint(-4, 4)), fill=(38, 31, 22, 22), width=1)
    return image


def add_stains(image: Image.Image, seed: int, count: int = 10) -> None:
    rng = random.Random(seed)
    stains = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(stains)
    for _ in range(count):
        x = rng.randint(-80, image.width + 40)
        y = rng.randint(-60, image.height + 40)
        rx = rng.randint(35, 145)
        ry = rng.randint(18, 90)
        draw.ellipse((x - rx, y - ry, x + rx, y + ry), fill=(88, 54, 27, rng.randint(10, 27)))
    image.alpha_composite(stains.filter(ImageFilter.GaussianBlur(18)))


def add_vignette(image: Image.Image, color: tuple[int, int, int] = (17, 19, 14)) -> None:
    layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    for inset in range(0, 86, 6):
        alpha = max(0, 14 - inset // 8)
        draw.rectangle((inset, inset, image.width - inset - 1, image.height - inset - 1), outline=color + (alpha,), width=7)
    image.alpha_composite(layer)


def paper_sheet(size: tuple[int, int], seed: int, base: tuple[int, int, int, int] = PAPER) -> Image.Image:
    sheet = textured_surface(size, base, seed, max(500, size[0] * size[1] // 420))
    add_stains(sheet, seed + 1, 8)
    sheet.putalpha(torn_mask(size, seed + 2))
    return sheet


def draw_map_content(sheet: Image.Image, seed: int, label: str = "KNOX COUNTRY") -> None:
    draw = ImageDraw.Draw(sheet)
    width, height = sheet.size
    rng = random.Random(seed)
    road = (77, 78, 58, 135)
    thin = max(2, width // 260)

    for x in (0.12, 0.28, 0.47, 0.68, 0.84):
        skew = rng.randint(-35, 35)
        px = int(width * x)
        draw.line((px, 30, px + skew, height - 28), fill=(248, 237, 201, 190), width=thin * 6)
        draw.line((px, 30, px + skew, height - 28), fill=road, width=thin)
    for y in (0.18, 0.36, 0.58, 0.78):
        skew = rng.randint(-28, 28)
        py = int(height * y)
        draw.line((24, py, width - 24, py + skew), fill=(248, 237, 201, 190), width=thin * 6)
        draw.line((24, py, width - 24, py + skew), fill=road, width=thin)

    block_colors = ((92, 104, 72, 94), (117, 86, 59, 74), (64, 76, 58, 70))
    for _ in range(24):
        x = rng.randint(45, max(46, width - 125))
        y = rng.randint(55, max(56, height - 95))
        w = rng.randint(38, 95)
        h = rng.randint(22, 62)
        draw.rectangle((x, y, x + w, y + h), fill=rng.choice(block_colors), outline=(55, 55, 42, 75), width=1)

    for index in range(4):
        inset = 42 + index * 24
        draw.arc((width * 0.48 - inset, height * 0.18 - inset, width * 0.88 + inset, height * 0.72 + inset), 195, 505, fill=(91, 83, 58, 92), width=2)

    draw.line((width // 2, 14, width // 2, height - 14), fill=(85, 66, 45, 52), width=5)
    draw.line((16, height // 2, width - 16, height // 2), fill=(85, 66, 45, 44), width=4)
    draw.line((width // 2 + 5, 14, width // 2 + 5, height - 14), fill=(255, 250, 224, 42), width=2)

    stamp_font = fit_font(draw, label, int(width * 0.48), max(22, width // 19), 18, "impact.ttf", "arialbd.ttf")
    box = draw.textbbox((0, 0), label, font=stamp_font)
    sw = box[2] - box[0]
    sh = box[3] - box[1]
    sx, sy = width - sw - 54, 26
    draw.rectangle((sx - 16, sy - 8, sx + sw + 16, sy + sh + 17), outline=(74, 67, 48, 155), width=4)
    draw.text((sx, sy), label, font=stamp_font, fill=(67, 62, 45, 175))


def map_sheet(size: tuple[int, int], seed: int, label: str = "KNOX COUNTRY") -> Image.Image:
    sheet = paper_sheet(size, seed)
    draw_map_content(sheet, seed + 10, label)
    return sheet


def draw_route(draw: ImageDraw.ImageDraw, points: tuple[tuple[int, int], ...]) -> None:
    for start, end in zip(points, points[1:]):
        dx, dy = end[0] - start[0], end[1] - start[1]
        distance = math.hypot(dx, dy)
        dash = 24
        for offset in range(0, int(distance), dash * 2):
            t1 = offset / distance
            t2 = min(1.0, (offset + dash) / distance)
            draw.line(
                (start[0] + dx * t1, start[1] + dy * t1, start[0] + dx * t2, start[1] + dy * t2),
                fill=(120, 39, 30, 220),
                width=7,
            )


def draw_pin(draw: ImageDraw.ImageDraw, center: tuple[int, int], radius: int = 20, color: tuple[int, int, int, int] = BLOOD) -> None:
    x, y = center
    draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=color, outline=(244, 221, 155, 230), width=max(3, radius // 5))
    draw.ellipse((x - radius // 3, y - radius // 3, x + radius // 3, y + radius // 3), fill=(38, 31, 22, 210))


def draw_compass(draw: ImageDraw.ImageDraw, center: tuple[int, int], radius: int) -> None:
    x, y = center
    draw.ellipse((x - radius, y - radius, x + radius, y + radius), outline=(56, 55, 39, 150), width=4)
    draw.line((x, y - radius, x, y + radius), fill=(56, 55, 39, 165), width=4)
    draw.line((x - radius, y, x + radius, y), fill=(56, 55, 39, 165), width=4)
    draw.polygon(((x, y - radius + 8), (x - 12, y + 12), (x, y), (x + 12, y + 12)), fill=(112, 38, 31, 210))
    small = font(max(18, radius // 3), "arialbd.ttf")
    draw.text((x - 8, y - radius - 28), "N", font=small, fill=INK)


def draw_paw_print(draw: ImageDraw.ImageDraw, center: tuple[int, int], scale: float, fill: tuple[int, int, int, int]) -> None:
    x, y = center
    draw.ellipse((x - 22 * scale, y - 8 * scale, x + 22 * scale, y + 28 * scale), fill=fill)
    for dx, dy in ((-27, -24), (-9, -35), (12, -35), (30, -22)):
        draw.ellipse((x + (dx - 9) * scale, y + (dy - 12) * scale, x + (dx + 9) * scale, y + (dy + 12) * scale), fill=fill)


def add_blood_splatter(image: Image.Image, center: tuple[int, int], seed: int) -> None:
    rng = random.Random(seed)
    layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    x, y = center
    draw.ellipse((x - 24, y - 17, x + 30, y + 22), fill=BLOOD)
    for _ in range(15):
        angle = rng.random() * math.tau
        distance = rng.randint(28, 105)
        radius = rng.randint(3, 10)
        px = x + int(math.cos(angle) * distance)
        py = y + int(math.sin(angle) * distance)
        draw.ellipse((px - radius, py - radius, px + radius, py + radius), fill=(95, 32, 25, rng.randint(90, 180)))
    image.alpha_composite(layer)


def mascot_fragment(
    mascot: Image.Image,
    crop_box: tuple[float, float, float, float],
    width: int,
    angle: float,
    seed: int,
) -> Image.Image:
    box = tuple(round(value * mascot.width) for value in crop_box)
    crop = mascot.crop(box)
    height = round(width * crop.height / crop.width)
    crop = crop.resize((width, height), Image.Resampling.LANCZOS)
    crop.putalpha(torn_mask(crop.size, seed, step=20, bite=14))
    return rotate_art(crop, angle)


def tape(size: tuple[int, int], seed: int, color: tuple[int, int, int, int] = (207, 186, 125, 180)) -> Image.Image:
    strip = textured_surface(size, color, seed, 90)
    strip.putalpha(torn_mask(size, seed + 1, step=14, bite=7))
    return strip


def distressed_text(
    text: str,
    text_font: ImageFont.FreeTypeFont | ImageFont.ImageFont,
    fill: tuple[int, int, int, int],
    stroke_fill: tuple[int, int, int, int],
    stroke_width: int,
    seed: int,
) -> Image.Image:
    probe = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    box = probe.textbbox((0, 0), text, font=text_font, stroke_width=stroke_width)
    width = box[2] - box[0] + 28
    height = box[3] - box[1] + 28
    art = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    draw = ImageDraw.Draw(art)
    draw.text((14 - box[0], 14 - box[1]), text, font=text_font, fill=fill, stroke_width=stroke_width, stroke_fill=stroke_fill)
    rng = random.Random(seed)
    for _ in range(max(5, width // 65)):
        x = rng.randint(8, max(8, width - 28))
        y = rng.randint(9, max(9, height - 10))
        draw.line((x, y, min(width - 5, x + rng.randint(9, 34)), y + rng.randint(-2, 2)), fill=(0, 0, 0, 0), width=rng.randint(1, 3))
    return art


def caution_label(text: str, size: tuple[int, int], seed: int) -> Image.Image:
    label = Image.new("RGBA", size, GOLD)
    draw = ImageDraw.Draw(label)
    stripe = max(22, size[1] // 3)
    for x in range(-size[1], size[0] + size[1], stripe * 2):
        draw.polygon(((x, 0), (x + stripe, 0), (x + stripe + size[1], size[1]), (x + size[1], size[1])), fill=(38, 36, 27, 255))
    draw.rectangle((18, 15, size[0] - 18, size[1] - 15), fill=(209, 165, 54, 245), outline=(35, 34, 27, 255), width=5)
    text_font = fit_font(draw, text, size[0] - 60, size[1] - 34, 24, "impact.ttf", "arialbd.ttf")
    box = draw.textbbox((0, 0), text, font=text_font)
    draw.text(((size[0] - box[2]) // 2, (size[1] - (box[3] - box[1])) // 2 - box[1]), text, font=text_font, fill=INK)
    label.putalpha(torn_mask(size, seed, step=18, bite=5))
    return label


def title_board(size: tuple[int, int], seed: int, color: tuple[int, int, int, int]) -> Image.Image:
    board = textured_surface(size, color, seed, 700)
    draw = ImageDraw.Draw(board)
    for y in range(28, size[1], 56):
        draw.line((10, y, size[0] - 10, y + 4), fill=(18, 17, 12, 55), width=3)
        draw.line((10, y + 7, size[0] - 10, y + 8), fill=(190, 171, 118, 28), width=1)
    board.putalpha(torn_mask(size, seed + 1, step=30, bite=9))
    return board


def draw_main_poster(mascot: Image.Image) -> Image.Image:
    image = textured_surface((WORK_SIZE, WORK_SIZE), DARK_GREEN, 410, 3300)
    draw = ImageDraw.Draw(image)
    for x in range(-180, WORK_SIZE + 180, 110):
        draw.polygon(((x, 0), (x + 48, 0), (x - 42, 72), (x - 90, 72)), fill=(19, 21, 17, 105))
    draw.rectangle((0, 70, WORK_SIZE, 82), fill=(204, 161, 53, 165))

    portrait = mascot_fragment(mascot, (0.05, 0.0, 0.95, 0.88), 500, 8, 420)
    add_shadowed_art(image, portrait, (510, -74), blur=18, offset=(10, 18), opacity=150)

    map_art = map_sheet((930, 660), 430)
    map_draw = ImageDraw.Draw(map_art)
    draw_route(map_draw, ((110, 510), (280, 430), (435, 470), (610, 320), (790, 360)))
    draw_pin(map_draw, (110, 510), 18)
    draw_pin(map_draw, (790, 360), 21)
    draw_compass(map_draw, (760, 525), 66)
    draw_paw_print(map_draw, (255, 555), 0.82, (64, 61, 45, 105))
    map_art = rotate_art(map_art, -2.4)
    add_shadowed_art(image, map_art, (42, 322), blur=18, offset=(10, 16), opacity=145)

    board = title_board((540, 258), 440, (45, 43, 30, 255))
    add_shadowed_art(image, rotate_art(board, -1.2), (35, 62), blur=13, offset=(8, 13), opacity=150)
    composite_at(image, rotate_art(tape((190, 46), 441), -7), (12, 45))
    composite_at(image, rotate_art(tape((180, 44), 442), 6), (410, 47))

    title_layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    td = ImageDraw.Draw(title_layer)
    brand_font = fit_font(td, "Minidoracat", 470, 66, 46, "arialbd.ttf", "segoeuib.ttf")
    title_font = fit_font(td, "MINIMAP", 490, 142, 96, "impact.ttf", "arialbd.ttf")
    subtitle_font = fit_font(td, "for Build 42", 350, 45, 32, "arialbd.ttf", "segoeuib.ttf")
    brand = distressed_text("Minidoracat", brand_font, PALE_PAPER, (25, 25, 19, 255), 3, 443)
    title = distressed_text("MINIMAP", title_font, (235, 192, 72, 255), (20, 19, 16, 255), 5, 444)
    composite_at(title_layer, brand, (68, 80))
    composite_at(title_layer, title, (55, 136))
    td.text((75, 270), "for Build 42", font=subtitle_font, fill=(238, 225, 183, 255))
    image.alpha_composite(title_layer)

    note = paper_sheet((92, 96), 450, (233, 206, 91, 255))
    nd = ImageDraw.Draw(note)
    bang = font(65, "impact.ttf", "arialbd.ttf")
    nd.text((33, 9), "!", font=bang, fill=(82, 39, 31, 255))
    add_shadowed_art(image, rotate_art(note, 8), (878, 238), blur=7, offset=(5, 7), opacity=100)
    add_blood_splatter(image, (914, 900), 460)
    add_vignette(image)
    return image


def small_map(size: tuple[int, int], seed: int, label: str, angle: float) -> Image.Image:
    sheet = map_sheet(size, seed, label)
    draw = ImageDraw.Draw(sheet)
    draw_pin(draw, (size[0] // 2, size[1] // 2), 14, (104, 35, 29, 230))
    return rotate_art(sheet, angle)


def draw_string_board(draw: ImageDraw.ImageDraw, points: tuple[tuple[int, int], ...]) -> None:
    for start, end in zip(points, points[1:]):
        draw.line((start, end), fill=(112, 27, 24, 225), width=7)
        draw.line((start[0] + 3, start[1] + 2, end[0] + 3, end[1] + 2), fill=(197, 76, 57, 95), width=2)
    for point in points:
        draw_pin(draw, point, 17, (143, 45, 32, 255))


def draw_maps_poster(mascot: Image.Image) -> Image.Image:
    image = textured_surface((WORK_SIZE, WORK_SIZE), (112, 77, 45, 255), 510, 4300)
    draw = ImageDraw.Draw(image)
    for y in range(40, WORK_SIZE, 82):
        draw.line((0, y, WORK_SIZE, y + 16), fill=(61, 42, 28, 38), width=3)
    for x in range(28, WORK_SIZE, 76):
        draw.ellipse((x, 120 + (x * 7) % 760, x + 3, 123 + (x * 7) % 760), fill=(224, 183, 111, 45))

    cards = (
        (small_map((420, 290), 520, "FIRE DEPT", -8), (-90, 150)),
        (small_map((490, 330), 530, "ESTATE 39", 6), (360, 92)),
        (small_map((430, 300), 540, "CHINATOWN", -3), (520, 404)),
    )
    for card, xy in cards:
        add_shadowed_art(image, card, xy, blur=12, offset=(8, 12), opacity=125)

    strings = Image.new("RGBA", image.size, (0, 0, 0, 0))
    draw_string_board(ImageDraw.Draw(strings), ((175, 275), (490, 235), (756, 318), (700, 545), (340, 510), (175, 275)))
    image.alpha_composite(strings)

    portrait = mascot_fragment(mascot, (0.08, 0.0, 0.92, 0.86), 410, -9, 550)
    add_shadowed_art(image, portrait, (48, 292), blur=16, offset=(9, 16), opacity=150)

    foreground_map = small_map((470, 255), 560, "SAFE ROUTE?", 4)
    add_shadowed_art(image, foreground_map, (-28, 548), blur=14, offset=(8, 13), opacity=135)
    foreground_draw = Image.new("RGBA", image.size, (0, 0, 0, 0))
    fd = ImageDraw.Draw(foreground_draw)
    draw_pin(fd, (254, 590), 18)
    image.alpha_composite(foreground_draw)

    addon = caution_label("ADD-ON", (300, 104), 570)
    add_shadowed_art(image, rotate_art(addon, -2), (35, 28), blur=8, offset=(5, 8), opacity=120)

    board = title_board((946, 282), 580, (39, 37, 28, 255))
    add_shadowed_art(image, rotate_art(board, 0.8), (37, 724), blur=15, offset=(8, 15), opacity=165)
    composite_at(image, rotate_art(tape((190, 48), 581), -5), (9, 699))
    composite_at(image, rotate_art(tape((190, 48), 582), 5), (827, 704))

    title_layer = Image.new("RGBA", image.size, (0, 0, 0, 0))
    td = ImageDraw.Draw(title_layer)
    title_font = fit_font(td, "MOD MAPS", 840, 164, 112, "impact.ttf", "arialbd.ttf")
    subtitle_font = fit_font(td, "MiniMap Map Pack", 700, 54, 38, "arialbd.ttf", "segoeuib.ttf")
    title = distressed_text("MOD MAPS", title_font, (235, 224, 190, 255), (22, 21, 17, 255), 5, 583)
    composite_at(title_layer, title, ((WORK_SIZE - title.width) // 2, 760))
    subtitle_box = td.textbbox((0, 0), "MiniMap Map Pack", font=subtitle_font)
    subtitle_width = subtitle_box[2] - subtitle_box[0]
    td.rectangle((154, 916, 870, 978), fill=(82, 91, 58, 235), outline=(197, 165, 75, 220), width=3)
    td.text(((WORK_SIZE - subtitle_width) // 2, 925), "MiniMap Map Pack", font=subtitle_font, fill=(244, 225, 161, 255))
    image.alpha_composite(title_layer)

    paw = Image.new("RGBA", (130, 130), (0, 0, 0, 0))
    draw_paw_print(ImageDraw.Draw(paw), (65, 70), 0.9, (52, 45, 31, 120))
    composite_at(image, rotate_art(paw, -12), (850, 580))
    add_blood_splatter(image, (70, 888), 590)
    add_vignette(image, (25, 18, 12))
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
