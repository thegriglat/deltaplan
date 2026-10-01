#!/usr/bin/env python3
"""Преобразование рендеров крыльев PNG → JPEG с обрезкой и центровкой.

Для каждого <id>/iso45.png: найти рамку содержимого (пиксели, отличающиеся
от цвета фона), вырезать, вписать в 1280×720 с полем ≈5% и цветом фона,
сохранить JPEG quality 85 (или 80 если > 250 КБ), optimize.
Выход: docs/models/screenshots/glider_<id>/iso45.jpg.

Использование: uv run -q --with pillow python tools/blender/wings_site_jpg.py <каталог_png> <каталог_вывода>
"""
import os
import sys
from pathlib import Path

from PIL import Image

# Цвет фона из render_views.py: (0.80, 0.81, 0.83) в sRGB → (204, 206, 211) в 8-бит RGB
BG_RGB = (204, 206, 211)
THRESHOLD = 6  # порог отличия от фона (0-255)
OUTPUT_SIZE = (1280, 720)
PADDING_PCT = 0.035  # поле ~3.5% для соответствия минимуму 40 КБ
QUALITY_HIGH = 85
QUALITY_LOW = 80
MAX_SIZE_KB = 250


def get_bg_color_from_png(png_path: Path) -> tuple:
    """Получить цвет фона из угла PNG."""
    img = Image.open(png_path)
    # Возьмём цвет из угла (например, верхний левый пиксель)
    pixel = img.getpixel((0, 0))
    if isinstance(pixel, tuple):
        return pixel[:3]  # RGB, игнорируем альфу если есть
    return (pixel, pixel, pixel)


def find_content_bounds(img: Image.Image, bg_color: tuple) -> tuple | None:
    """Найти ограничивающий прямоугольник содержимого (пиксели ≠ фона).

    Возвращает (left, top, right, bottom) или None если не найдено.
    """
    pixels = img.load()
    width, height = img.size

    left, top, right, bottom = width, height, 0, 0
    found = False

    for y in range(height):
        for x in range(width):
            pixel = pixels[x, y]
            # Сравнить RGB (игнорируем альфу если есть)
            if isinstance(pixel, tuple):
                r, g, b = pixel[:3]
            else:
                r = g = b = pixel

            # Проверить, отличается ли от фона
            if abs(r - bg_color[0]) > THRESHOLD or \
               abs(g - bg_color[1]) > THRESHOLD or \
               abs(b - bg_color[2]) > THRESHOLD:
                left = min(left, x)
                top = min(top, y)
                right = max(right, x)
                bottom = max(bottom, y)
                found = True

    if not found:
        return None

    return (left, top, right + 1, bottom + 1)


def fit_with_padding(content_size: tuple, padding_pct: float, output_size: tuple) -> tuple:
    """Вычислить размер и позицию содержимого с полем в выходном кадре.

    Возвращает (new_width, new_height, offset_x, offset_y).
    """
    content_w, content_h = content_size
    out_w, out_h = output_size
    aspect = content_w / content_h

    # Вычислить размер с полем
    available_w = out_w * (1 - 2 * padding_pct)
    available_h = out_h * (1 - 2 * padding_pct)

    # Масштабировать так, чтобы вписалось в доступное пространство
    if aspect > available_w / available_h:
        # Ограничена по ширине
        new_w = int(available_w)
        new_h = int(new_w / aspect)
    else:
        # Ограничена по высоте
        new_h = int(available_h)
        new_w = int(new_h * aspect)

    # Центрировать
    offset_x = (out_w - new_w) // 2
    offset_y = (out_h - new_h) // 2

    return (new_w, new_h, offset_x, offset_y)


def process_wing(png_path: Path, output_dir: Path, wing_id: str, bg_color: tuple) -> None:
    """Обработать один рендер крыла."""
    img = Image.open(png_path).convert('RGB')

    # Найти рамку содержимого
    bounds = find_content_bounds(img, bg_color)
    if bounds is None:
        print(f"WARNING: {wing_id} — содержимое не найдено, пропуск", file=sys.stderr)
        return

    left, top, right, bottom = bounds
    cropped = img.crop((left, top, right, bottom))

    # Вписать с полем в выходной размер
    content_size = cropped.size
    new_w, new_h, offset_x, offset_y = fit_with_padding(
        content_size, PADDING_PCT, OUTPUT_SIZE
    )

    # Создать выходное изображение с фоном
    output_img = Image.new('RGB', OUTPUT_SIZE, bg_color)
    resized = cropped.resize((new_w, new_h), Image.Resampling.LANCZOS)
    output_img.paste(resized, (offset_x, offset_y))

    # Сохранить JPEG
    output_path = output_dir / f"glider_{wing_id}" / "iso45.jpg"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    # Первая попытка с quality 85
    output_img.save(str(output_path), 'JPEG', quality=QUALITY_HIGH, optimize=True)

    # Если слишком большой, переоформить с quality 80
    file_size_kb = output_path.stat().st_size / 1024
    if file_size_kb > MAX_SIZE_KB:
        output_img.save(str(output_path), 'JPEG', quality=QUALITY_LOW, optimize=True)
        file_size_kb = output_path.stat().st_size / 1024

    print(f"{wing_id}: {file_size_kb:.1f} КБ")


def main() -> None:
    if len(sys.argv) < 3:
        print("Использование: python wings_site_jpg.py <каталог_png> <каталог_вывода>",
              file=sys.stderr)
        sys.exit(1)

    png_dir = Path(sys.argv[1])
    output_base = Path(sys.argv[2])

    if not png_dir.exists():
        print(f"Ошибка: {png_dir} не существует", file=sys.stderr)
        sys.exit(1)

    total_size = 0
    processed = 0

    # Обработать все субдиректории <id>/iso45.png
    for wing_dir in sorted(png_dir.iterdir()):
        if not wing_dir.is_dir():
            continue

        wing_id = wing_dir.name
        png_path = wing_dir / "iso45.png"

        if not png_path.exists():
            print(f"WARNING: {wing_id}/iso45.png не найден", file=sys.stderr)
            continue

        # Получить цвет фона
        bg_color = get_bg_color_from_png(png_path)

        try:
            process_wing(png_path, output_base, wing_id, bg_color)
            jpg_path = output_base / f"glider_{wing_id}" / "iso45.jpg"
            if jpg_path.exists():
                total_size += jpg_path.stat().st_size
                processed += 1
        except Exception as e:
            print(f"ERROR: {wing_id} — {e}", file=sys.stderr)

    total_mb = total_size / (1024 * 1024)
    print(f"\nВсего: {processed} крыльев, {total_mb:.2f} МБ")

    if total_mb > 8:
        print(f"Предупреждение: общий размер превышает 8 МБ", file=sys.stderr)


if __name__ == "__main__":
    main()
