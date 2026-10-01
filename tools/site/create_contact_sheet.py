#!/usr/bin/env python3
"""Создать контактный лист всех 48 крыльев (8×6 сетка с подписями)."""
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def create_contact_sheet(output_path: Path) -> None:
    """Создать контактный лист из всех JPEG-рендеров крыльев."""

    # Параметры сетки
    cols = 6
    rows = 8
    thumb_w, thumb_h = 213, 120  # размер миниатюры
    padding = 10
    label_h = 20
    margin = 10

    # Общие размеры
    grid_w = cols * (thumb_w + padding) + 2 * margin - padding
    grid_h = rows * (thumb_h + label_h + padding) + 2 * margin - padding

    # Создать фоновое изображение (серое, как в рендерах)
    bg_color = (204, 206, 211)
    sheet = Image.new('RGB', (grid_w, grid_h), bg_color)
    draw = ImageDraw.Draw(sheet)

    # Загрузить все JPEG-файлы
    screenshot_dir = Path(__file__).parent.parent.parent / "docs" / "models" / "screenshots"

    wing_dirs = sorted([d for d in screenshot_dir.glob("glider_*") if d.is_dir()])

    if len(wing_dirs) != 48:
        print(f"Warning: expected 48 wings, found {len(wing_dirs)}", file=sys.stderr)

    # Расположить миниатюры в сетке
    try:
        # Попробовать загрузить шрифт
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 12)
    except Exception:
        # Fallback на дефолтный шрифт если не найти
        font = ImageFont.load_default()

    for idx, wing_dir in enumerate(wing_dirs[:48]):  # только первые 48
        row = idx // cols
        col = idx % cols

        x = margin + col * (thumb_w + padding)
        y = margin + row * (thumb_h + label_h + padding)

        wing_id = wing_dir.name.replace("glider_", "")
        jpg_path = wing_dir / "iso45.jpg"

        if jpg_path.exists():
            try:
                # Загрузить изображение
                img = Image.open(jpg_path).convert('RGB')
                # Масштабировать до размера миниатюры
                img.thumbnail((thumb_w, thumb_h), Image.Resampling.LANCZOS)

                # Вставить в сетку
                sheet.paste(img, (x, y))

                # Нарисовать подпись
                text_y = y + thumb_h + 2
                draw.text((x, text_y), wing_id, fill=(0, 0, 0), font=font)

            except Exception as e:
                print(f"Error processing {wing_id}: {e}", file=sys.stderr)
        else:
            print(f"Warning: {jpg_path} not found", file=sys.stderr)

    # Сохранить контактный лист
    output_path.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(str(output_path), 'JPEG', quality=85, optimize=True)
    print(f"Contact sheet: {output_path}")


if __name__ == "__main__":
    if len(sys.argv) > 1:
        output = Path(sys.argv[1])
    else:
        # Default path
        output = Path(__file__).parent.parent.parent / "build" / "screenshots" / "site" / "SU-3" / "00_все_крылья.jpg"

    create_contact_sheet(output)
