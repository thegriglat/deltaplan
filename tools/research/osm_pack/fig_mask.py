"""Картинка-проверка маски озёр: Бохинь, маска 10 м (серое) + вектор озёр из той же ячейки (красный).

    python -I fig_mask.py <out_min> <out.jpg> [lon lat km]
"""
import json
import math
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).parent))
import osmpack as op  # noqa: E402
import build_min as bm  # noqa: E402,F401

out, dst = Path(sys.argv[1]), sys.argv[2]
lon, lat, km = (float(x) for x in sys.argv[3:6]) if len(sys.argv) > 5 else (13.88, 46.28, 6.0)
ix, iy = math.floor(lon / 0.25), math.floor(lat / 0.25)
nm = op.cell_name(ix, iy)
d = out / "detail"
raw = (d / "cells" / f"{nm}.mask").read_bytes()
w, h = int.from_bytes(raw[:2], "little"), int.from_bytes(raw[2:4], "little")
m = np.unpackbits(np.frombuffer(raw[4:], np.uint8).reshape(h, -1), axis=1)[:, :w]
lon0, lat0, kx, ky = op.cell_origin(ix, iy)
cx, cy = (lon - lon0) * kx, (lat - lat0) * ky
half = km * 500
x0, x1 = int((cx - half) / 10), int((cx + half) / 10)
y0, y1 = int((cy - half) / 10), int((cy + half) / 10)
crop = m[y0:y1, x0:x1][::-1]          # север сверху
S = 2
img = Image.fromarray((255 - crop * 140).astype(np.uint8)).resize(
    (crop.shape[1] * S, crop.shape[0] * S), Image.NEAREST).convert("RGB")
dr = ImageDraw.Draw(img)
classes = json.loads((d / "classes.json").read_text())
cells = op.decode_cell((d / "cells" / f"{nm}.bin").read_bytes(), classes)
nl = 0
for obj in cells.get("lakes", []):
    for xs, ys in obj[5]:
        pts = [((x - x0 * 10) / 10 * S, (y1 * 10 - y) / 10 * S) for x, y in zip(xs, ys)]
        if any(0 <= p[0] < img.width and 0 <= p[1] < img.height for p in pts):
            dr.line(pts + [pts[0]], fill=(220, 30, 30), width=1)
            nl += 1
img.save(dst, quality=80)
print(nm, img.size, "колец в кадре", nl, "пикселей воды в кадре", int(crop.sum()))
