"""Сравнение двух папок места: высоты (detail, far) и карты классов — числами, не байтами WebP."""
import sys
from pathlib import Path
import numpy as np
from PIL import Image
a, b = Path(sys.argv[1]), Path(sys.argv[2])
ok = True
for f in ("detail.webp", "far.webp", "detail_surface.webp", "far_surface.webp", "detail_water.webp"):
    x = np.array(Image.open(a / f).convert("RGB" if f in ("detail.webp", "far.webp") else "L")).astype(np.int64)
    y = np.array(Image.open(b / f).convert("RGB" if f in ("detail.webp", "far.webp") else "L")).astype(np.int64)
    if f in ("detail.webp", "far.webp"):
        x = (x[..., 0] << 16) | (x[..., 1] << 8) | x[..., 2]
        y = (y[..., 0] << 16) | (y[..., 1] << 8) | y[..., 2]
        d = np.abs(x - y) * 0.03125
        print(f"{f}: макс разница высот {d.max():.3f} м, доля отличающихся {np.mean(d > 0):.4f}")
        ok &= d.max() < 1.0
    else:
        fr = np.mean(x != y)
        print(f"{f}: доля отличающихся {fr:.4f}")
        ok &= fr < 0.01
print("ИТОГ:", "OK" if ok else "РАЗЛИЧИЯ")
