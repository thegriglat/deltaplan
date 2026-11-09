"""TB-18: сетка высот вокруг центра Алтая (соседний к югу участок) из тайлов Terrarium (AWS Terrain Tiles; кеш игры ~/.local/share/Deltaplan/terrain_cache/terrarium/12).
Пишет out/round3_ground_dem.f32: 401×401 float32, шаг 30 м, ось x на восток, строки с юга на север? — см. README ниже:
индекс [j][i], x = (i-200)*30, z = (j-200)*30 (z — на юг, как в мире игры: −Z — север). Лицензия данных — Terrain Tiles (SRTM/ASTER/и др., открытые)."""
import math, sys
from pathlib import Path
import numpy as np
from PIL import Image

LAT, LON, Z = 50.7086, 86.1768, 12  # центр тайла 12/3028/1376: Алтай в ~10 км к югу от Онгудая (тайлов Онгудая в кеше нет — Copernicus)
N, STEP = 401, 30.0
out = Path(__file__).resolve().parent.parent / "out" / "round3_ground_dem.f32"
cache = Path.home() / ".local/share/Deltaplan/terrain_cache/terrarium" / str(Z)
n = 2 ** Z
mpp = 156543.03392 * math.cos(math.radians(LAT)) / (2 ** Z)  # при тайле 256 px: м/px = C*cos/2^z (C для 256 px на z=0)
px0 = (LON + 180) / 360 * n * 256
py0 = (1 - math.asinh(math.tan(math.radians(LAT))) / math.pi) / 2 * n * 256
tiles = {}
def tile(tx, ty):
    if (tx, ty) not in tiles:
        p = cache / str(tx) / f"{ty}.png"
        if not p.exists():
            sys.exit(f"нет тайла {p}")
        a = np.asarray(Image.open(p).convert("RGB"), float)
        tiles[(tx, ty)] = a[..., 0] * 256 + a[..., 1] + a[..., 2] / 256 - 32768
    return tiles[(tx, ty)]
H = np.zeros((N, N), np.float32)
for j in range(N):
    for i in range(N):
        x, z = (i - 200) * STEP, (j - 200) * STEP
        px, py = px0 + x / mpp, py0 + z / mpp
        tx, ty = int(px // 256), int(py // 256)
        fx, fy = px - tx * 256, py - ty * 256
        t = tile(tx, ty)
        ix, iy = min(int(fx), 255), min(int(fy), 255)
        H[j, i] = t[iy, ix]
out.parent.mkdir(exist_ok=True)
H.tofile(out)
dx = np.gradient(H, STEP, axis=1); dz = np.gradient(H, STEP, axis=0)
sl = np.degrees(np.arctan(np.hypot(dx, dz)))
print("h min/med/max", H.min(), np.median(H), H.max(), "slope pct 25/50/75/90", np.percentile(sl, [25, 50, 75, 90]).round(1), "центр", H[200, 200])
