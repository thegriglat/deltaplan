#!/usr/bin/env python3
"""Подписи для вертикального среза поля (AM-10, дополнение к WF-09): оси (км / м), шкала цвета
w (м/с), заголовок (место, час, ветер). dump_slices.gd рисует только заливку и не умеет текст
(headless без окна) — эту надпись накладывает PIL поверх готового PNG + сайдкара <имя>.json.

Использование:
    python3 annotate_slice.py <срез.png> [<срез.json>] [--out <путь>]
Без --out — перезаписывает <срез.png> на месте.
"""

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

FONT_PATHS = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
]
MARGIN_L = 70
MARGIN_B = 40
MARGIN_T = 46
MARGIN_R = 90
BG = (255, 255, 255)


def _font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    path = FONT_PATHS[1] if bold and Path(FONT_PATHS[1]).exists() else FONT_PATHS[0]
    return ImageFont.truetype(path, size)


def annotate(png_path: Path, meta: dict) -> Image.Image:
    src = Image.open(png_path).convert("RGB")
    w, h = src.size
    out = Image.new("RGB", (w + MARGIN_L + MARGIN_R, h + MARGIN_T + MARGIN_B), BG)
    out.paste(src, (MARGIN_L, MARGIN_T))
    d = ImageDraw.Draw(out)
    f_axis = _font(13)
    f_title = _font(15, bold=True)
    f_label = _font(13, bold=True)

    half_km = meta.get("half_len_m", 0.0) / 1000.0
    h_top = meta.get("h_top_m", 0.0)
    w_scale = meta.get("w_scale_ms", 1.0)

    # рамка среза
    d.rectangle(
        [MARGIN_L, MARGIN_T, MARGIN_L + w - 1, MARGIN_T + h - 1], outline=(0, 0, 0), width=1
    )

    # ось X — расстояние вдоль ветра, км (0 — точка среза)
    for frac, val in [(0.0, -half_km), (0.5, 0.0), (1.0, half_km)]:
        x = MARGIN_L + int(frac * (w - 1))
        d.line([(x, MARGIN_T + h), (x, MARGIN_T + h + 5)], fill=(0, 0, 0))
        txt = f"{val:+.1f}"
        tw = d.textlength(txt, font=f_axis)
        d.text((x - tw / 2, MARGIN_T + h + 8), txt, fill=(0, 0, 0), font=f_axis)
    d.text(
        (MARGIN_L + w / 2 - 60, MARGIN_T + h + 24),
        "расстояние вдоль ветра, км",
        fill=(0, 0, 0),
        font=f_axis,
    )

    # ось Y — высота над точкой среза, м (0 внизу, растёт вверх)
    for frac in [0.0, 0.25, 0.5, 0.75, 1.0]:
        y = MARGIN_T + h - int(frac * (h - 1))
        val = frac * h_top
        d.line([(MARGIN_L - 5, y), (MARGIN_L, y)], fill=(0, 0, 0))
        txt = f"{val:.0f}"
        tw = d.textlength(txt, font=f_axis)
        d.text((MARGIN_L - 10 - tw, y - 6), txt, fill=(0, 0, 0), font=f_axis)
    ylabel = Image.new("RGBA", (170, 20), (255, 255, 255, 0))
    dl = ImageDraw.Draw(ylabel)
    dl.text((0, 0), "высота над точкой среза, м", fill=(0, 0, 0), font=f_axis)
    ylabel = ylabel.rotate(90, expand=True)
    out.paste(ylabel, (2, MARGIN_T + h // 2 - 85), ylabel)

    # шкала цвета w (диагональная бело-сине-красная, как _diverging в dump_slices.gd)
    bar_x = MARGIN_L + w + 18
    bar_top = MARGIN_T
    bar_h = h
    for j in range(bar_h):
        t = 1.0 - 2.0 * j / (bar_h - 1)  # +1 сверху (подъём) .. -1 снизу (опускание)
        if t >= 0:
            col = tuple(int(255 + t * (c - 255)) for c in (242, 38, 13))
        else:
            col = tuple(int(255 + (-t) * (c - 255)) for c in (13, 89, 230))
        d.line([(bar_x, bar_top + j), (bar_x + 16, bar_top + j)], fill=col)
    d.rectangle([bar_x, bar_top, bar_x + 16, bar_top + bar_h - 1], outline=(0, 0, 0), width=1)
    for frac, val in [(0.0, w_scale), (0.5, 0.0), (1.0, -w_scale)]:
        y = bar_top + int(frac * (bar_h - 1))
        d.text((bar_x + 20, y - 6), f"{val:+.1f}", fill=(0, 0, 0), font=f_axis)
    d.text((bar_x - 4, bar_top - 20), "w, м/с", fill=(0, 0, 0), font=f_label)

    # заголовок
    loc = meta.get("location", "")
    hour = meta.get("hour", -1)
    wind_ms = meta.get("wind_ms", 0.0)
    wdir = meta.get("wind_from_deg", 0.0)
    hour_s = f"{hour:.0f}:00" if hour >= 0 else "?"
    title = (
        f"{loc} — вертикальный срез вдоль ветра, {hour_s}, "
        f"ветер {wind_ms:.0f} м/с с {wdir:.0f}°"
    )
    d.text((MARGIN_L, 6), title, fill=(0, 0, 0), font=f_title)

    return out


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    png_path = Path(sys.argv[1])
    json_path = Path(sys.argv[2]) if len(sys.argv) > 2 and not sys.argv[2].startswith("--") else (
        png_path.with_suffix(".json")
    )
    out_path = png_path
    if "--out" in sys.argv:
        out_path = Path(sys.argv[sys.argv.index("--out") + 1])
    meta = {}
    if json_path.exists():
        meta = json.loads(json_path.read_text())
    else:
        print(f"annotate_slice: нет {json_path} — подписи по умолчанию", file=sys.stderr)
    img = annotate(png_path, meta)
    img.save(out_path)
    print(f"annotate_slice: {out_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
