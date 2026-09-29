"""Рельеф Онгудая для 3D-Пикара: чтение слоя detail (25 м), осреднение в клетки, места.

Координаты мира игры: X — восток, Z — юг (−Z — север), высота над морем. Узел (i, j) слоя:
x = origin_x + i·spacing, z = origin_z + j·spacing, строка j (row-major, float32 LE, gzip).
В решателе оси: i — X (восток), j — Y = −Z (север), k — высота. Поэтому при чтении строки
переворачиваются (j решателя растёт на север).
"""
from __future__ import annotations

import gzip
import json
import math
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
DATA = ROOT / "data/terrain/ongudai"
LOC = ROOT / "configs/locations/ongudai.json"
R_EARTH = 6371008.8


def load_detail(loc="ongudai"):
    DATA = ROOT / f"data/terrain/{loc}"
    meta = json.loads((DATA / "meta.json").read_text())
    lay = next(l for l in meta["layers"] if l["id"] == "detail")
    raw = gzip.decompress((DATA / lay["file"]).read_bytes())
    h = np.frombuffer(raw, "<f4").reshape(lay["height"], lay["width"]).astype(np.float64)
    # строка j растёт на юг (Z); решатель хочет север → переворот
    h = h[::-1].copy()
    info = dict(spacing=lay["spacing_m"], x0=lay["origin_x_m"],
                y0=-(lay["origin_z_m"] + (lay["height"] - 1) * lay["spacing_m"]))
    water = None
    try:
        from PIL import Image
        im = np.asarray(Image.open(DATA / lay["water_file"]).convert("L"), float)
        # маска воды — своё разрешение; растянем до сетки высот ближайшим
        ny, nx = h.shape
        jj = (np.arange(ny) * im.shape[0] / ny).astype(int)
        ii = (np.arange(nx) * im.shape[1] / nx).astype(int)
        water = (im[::-1][jj][:, ii] > 127)
    except Exception:
        pass
    return h, info, meta, water


def latlon_to_xy(lat, lon, meta):
    """Мир игры: x — восток, y — север (= −Z), м от центра (равнопромежуточно, как fetch_dem)."""
    lat0, lon0 = meta["center_lat"], meta["center_lon"]
    x = math.radians(lon - lon0) * R_EARTH * math.cos(math.radians(lat0))
    y = math.radians(lat - lat0) * R_EARTH
    return x, y


def sites(meta):
    loc = json.loads(LOC.read_text())
    s = loc["start_sites"][0]
    sx, sy = latlon_to_xy(s["lat"], s["lon"], meta)
    return dict(start=dict(name="Каянча, старт на юг", x=sx, y=sy, heading=s["heading_deg"]))


class Grid:
    """Сетка решателя: центр (xc, yc), клетка dx по горизонтали, dz по высоте, nx × ny × nz.
    Высоты клеток — среднее 25-метровых узлов в клетке (блочное осреднение)."""

    def __init__(self, dx, nx, ny, dz, z_bot, nz, xc=0.0, yc=0.0):
        self.dx, self.nx, self.ny, self.dz, self.nz = dx, nx, ny, dz, nz
        self.z_bot = z_bot
        self.xc, self.yc = xc, yc
        self.x0 = xc - nx * dx / 2
        self.y0 = yc - ny * dx / 2
        self.x = self.x0 + (np.arange(nx) + 0.5) * dx
        self.y = self.y0 + (np.arange(ny) + 0.5) * dx
        self.z = z_bot + (np.arange(nz) + 0.5) * dz


def block_mean(h, info, x0, y0, dx, nx, ny):
    s = info["spacing"]
    f = int(round(dx / s))
    assert abs(f * s - dx) < 1e-6, "клетка должна быть кратна 25 м"
    i0 = int(round((x0 - info["x0"]) / s))
    j0 = int(round((y0 - info["y0"]) / s))
    assert i0 >= 0 and j0 >= 0 and i0 + f * nx <= h.shape[1] and j0 + f * ny <= h.shape[0], \
        ("окно вне слоя detail", i0, j0)
    blk = h[j0:j0 + f * ny, i0:i0 + f * nx].reshape(ny, f, nx, f)
    return blk.mean(axis=(1, 3))


def slopes(hc, dx):
    """Градиент высоты (м/м) центральными разностями на сетке клеток: (dh/dx, dh/dy)."""
    gy, gx = np.gradient(hc, dx)
    return gx, gy


class Location:
    """Любое встроенное место: высоты слоя detail (оси решателя: i — восток, j — север), старты."""

    def __init__(self, loc_id):
        self.id = loc_id
        self.h, self.info, self.meta, water = load_detail(loc_id)
        self.water = None if water is None else water.astype(float)
        self.loc = json.loads((ROOT / f"configs/locations/{loc_id}.json").read_text())
        self.sites = {}
        for s in self.loc["start_sites"]:
            x, y = latlon_to_xy(s["lat"], s["lon"], self.meta)
            self.sites[s["id"]] = dict(name=s["id"], x=x, y=y, heading=s["heading_deg"])

    def height_at(self, x, z):
        """Высота в точке мира игры (x — восток, z — юг), билинейно."""
        y = -z
        s = self.info["spacing"]
        fi = (x - self.info["x0"]) / s
        fj = (y - self.info["y0"]) / s
        i0 = int(np.clip(np.floor(fi), 0, self.h.shape[1] - 2))
        j0 = int(np.clip(np.floor(fj), 0, self.h.shape[0] - 2))
        a, b = fi - i0, fj - j0
        h = self.h
        return float((1 - b) * ((1 - a) * h[j0, i0] + a * h[j0, i0 + 1]) + b * ((1 - a) * h[j0 + 1, i0] + a * h[j0 + 1, i0 + 1]))
