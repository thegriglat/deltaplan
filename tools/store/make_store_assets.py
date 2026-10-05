#!/usr/bin/env python3
"""Генератор графики страницы и библиотеки Steam (SA-К4 v2, docs/contracts/steam-assets.md).

Вход: кадры 3840x2160 из steam/store/src/*.jpg (первый по имени — основной фон; пока там
копия assets/ui/menu_background.jpg), assets/logo.png, assets/icon.png.
Выход: файлы в steam/store/ (размеры — таблица SA-К4). Повторный запуск даёт те же байты:
параметры сохранения фиксированы, метаданных (EXIF, время) нет.
Замена фона: положить новый кадр в steam/store/src/ (или заменить файл), запустить заново.
Запуск: uv run -q --no-project --with pillow python tools/store/make_store_assets.py
"""
import sys
from pathlib import Path
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "steam" / "store"
SRC = OUT / "src"

# Кадрирование: (cx, cy) — центр окна кадра в долях исходного кадра, zoom — доля высоты
# кадра, которую занимает окно (1.0 — вся высота). Дельтаплан в кадре справа, на 0.45–0.72
# по высоте; склон и горы — слева/внизу.
# Логотип: (ширина в долях ширины картинки, центр x, центр y в долях картинки).
# Файл: (размер, кадр(cx, cy, zoom), логотип или None)
SPECS = {
    "capsule_header.jpg":   ((920, 430),  (0.68, 0.56, 0.62), (0.50, 0.27, 0.30)),
    "library_header.jpg":   ((920, 430),  (0.68, 0.56, 0.62), (0.50, 0.27, 0.30)),
    "capsule_small.jpg":    ((462, 174),  (0.76, 0.56, 0.55), (0.52, 0.29, 0.50)),
    "capsule_main.jpg":     ((1232, 706), (0.62, 0.52, 0.80), (0.62, 0.50, 0.20)),
    "capsule_vertical.jpg": ((748, 896),  (0.76, 0.56, 1.00), (0.88, 0.50, 0.12)),
    "library_capsule.jpg":  ((600, 900),  (0.76, 0.56, 1.00), (0.88, 0.50, 0.12)),
    "page_background.jpg":  ((1438, 810), (0.50, 0.50, 1.00), None),
    "event_cover.jpg":      ((800, 450),  (0.60, 0.52, 0.85), (0.55, 0.50, 0.20)),
    "event_header.jpg":     ((1920, 622), (0.66, 0.56, 0.60), (0.40, 0.27, 0.34)),
    "library_hero.png":     ((3840, 1240), (0.50, 0.58, 0.575), None),
}


def crop_frame(img, size, cx, cy, zoom):
    w, h = size
    ch = img.height * zoom
    cw = ch * w / h
    if cw > img.width:
        cw = img.width
        ch = cw * h / w
    x0 = min(max(cx * img.width - cw / 2, 0), img.width - cw)
    y0 = min(max(cy * img.height - ch / 2, 0), img.height - ch)
    box = (round(x0), round(y0), round(x0 + cw), round(y0 + ch))
    return img.crop(box).resize(size, Image.LANCZOS).convert("RGBA")


def white_logo(logo, width, shadow=True):
    """Логотип (тёмно-синий на прозрачном) -> белый с мягкой тенью; прозрачный фон."""
    h = round(logo.height * width / logo.width)
    a = logo.getchannel("A").resize((width, h), Image.LANCZOS)
    pad = max(6, width // 40)
    canvas = (width + 2 * pad, h + 2 * pad)
    alpha = Image.new("L", canvas, 0)
    alpha.paste(a, (pad, pad))
    out = Image.new("RGBA", canvas, (0, 0, 0, 0))
    if shadow:
        sh = alpha.filter(ImageFilter.GaussianBlur(pad / 3)).point(lambda v: min(255, int(v * 0.8)))
        shadow_img = Image.new("RGBA", canvas, (0, 8, 24, 0))
        shadow_img.putalpha(sh)
        out = Image.alpha_composite(out, shadow_img.transform(canvas, Image.AFFINE, (1, 0, -pad / 6, 0, 1, -pad / 4)))
    white = Image.new("RGBA", canvas, (255, 255, 255, 0))
    white.putalpha(alpha)
    return Image.alpha_composite(out, white)


def put_logo(img, logo, spec):
    wf, fx, fy = spec
    lg = white_logo(logo, round(img.width * wf))
    x = round(fx * img.width - lg.width / 2)
    y = round(fy * img.height - lg.height / 2)
    img.alpha_composite(lg, (x, y))


def save(img, name):
    path = OUT / name
    if name.endswith(".jpg"):
        img.convert("RGB").save(path, "JPEG", quality=92, subsampling=0, optimize=False, progressive=False)
    elif name.endswith(".png"):
        img.save(path, "PNG", compress_level=9, optimize=False)
    print("OK", name, img.size)


def main():
    frames = sorted(SRC.glob("*.jpg"))
    if not frames:
        sys.exit("нет кадров в steam/store/src/")
    bg = Image.open(frames[0]).convert("RGB")
    if bg.size != (3840, 2160):
        sys.exit(f"кадр {frames[0].name}: {bg.size}, нужен 3840x2160")
    logo = Image.open(ROOT / "assets" / "logo.png").convert("RGBA")
    icon = Image.open(ROOT / "assets" / "icon.png").convert("RGBA")

    for name, (size, (cx, cy, zoom), lspec) in SPECS.items():
        img = crop_frame(bg, size, cx, cy, zoom)
        if lspec:
            put_logo(img, logo, lspec)
        if name == "library_hero.png":
            img = img.convert("RGB")  # без альфы
        save(img, name)

    # Library Logo: белый логотип с тенью на прозрачном фоне, ширина ровно 1280.
    ll = white_logo(logo, 1220)
    save(ll, "library_logo.png")

    # Иконки из assets/icon.png (256x256)
    flat = Image.new("RGBA", icon.size, (255, 255, 255, 255))
    flat.alpha_composite(icon)
    save(icon, "shortcut_icon.png")
    icon.save(OUT / "shortcut_icon.ico", format="ICO", sizes=[(256, 256), (128, 128), (64, 64), (48, 48), (32, 32), (16, 16)])
    print("OK shortcut_icon.ico")
    save(flat.resize((184, 184), Image.LANCZOS), "app_icon.jpg")


if __name__ == "__main__":
    main()
