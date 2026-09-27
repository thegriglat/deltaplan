"""Сжать PNG-скриншоты больше LIMIT: палитра 256 цветов (без дизеринга).
    uv run --with pillow python tools/blender/compress_png.py docs/models/screenshots
"""
import os
import sys

from PIL import Image

LIMIT = 280 * 1024

for root, _, files in os.walk(sys.argv[1]):
    for f in files:
        p = os.path.join(root, f)
        if f.endswith(".png") and os.path.getsize(p) > LIMIT:
            im = Image.open(p).convert("RGB")
            n = 256 if os.path.getsize(p) < 600 * 1024 else 96
            im.quantize(n, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).save(
                p, optimize=True)
            print("%s: %d КБ" % (p, os.path.getsize(p) // 1024))
