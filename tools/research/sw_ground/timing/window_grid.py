"""Сетка окна игры (rust/dp-air/src/field/window.rs: window_domain, window_vertical) и рельеф Онгудая (формат W1).

Оси решателя: x — восток, y — север (y = −z мира), строка растра места j идёт к +Z, т.е. к югу.
"""
import json
import pathlib

import numpy as np

ROOT = pathlib.Path(__file__).resolve().parents[4]
PLACE = ROOT / "tests" / "fixtures" / "wind" / "places"
CONFIGS = ROOT / "configs"
FOCUS_XZ = (7224.77490234375, 324.689636230469)    # focuses случая ongudai_day_1 / ongudai_strong (x, z мира)
N_WINDOW, TOP_ABOVE, CORNER_STEP = 64, 2000.0, 25.0


def load_ongudai(crop_m=None, centre=None):
    """→ dict(x, y (по возрастанию), z (ny, nx) м, cls (ny, nx)); y = −z мира, строки перевёрнуты на север."""
    meta = json.load(open(PLACE / "ongudai.json"))
    w, hgt = meta["grid"]["width"], meta["grid"]["height"]
    n = w * hgt
    raw = np.fromfile(PLACE / "ongudai.bin", dtype="<i2", count=n).reshape(hgt, w)
    z = raw.astype(float) * meta["h_scale"] + meta["h_offset"]
    cls = np.fromfile(PLACE / "ongudai.bin", dtype=np.uint8, count=n, offset=2 * n + n).reshape(hgt, w)
    x = meta["grid"]["origin_x"] + meta["grid"]["spacing"] * np.arange(w)
    zw = meta["grid"]["origin_z"] + meta["grid"]["spacing"] * np.arange(hgt)
    y = (-zw)[::-1]
    z, cls = z[::-1], cls[::-1]
    out = dict(x=x, y=y, z=z, cls=cls, spacing=meta["grid"]["spacing"])
    if crop_m:
        cx, cy = centre
        ix = (x >= cx - crop_m) & (x <= cx + crop_m)
        iy = (y >= cy - crop_m) & (y <= cy + crop_m)
        out = dict(x=x[ix], y=y[iy], z=z[np.ix_(iy, ix)], cls=cls[np.ix_(iy, ix)], spacing=meta["grid"]["spacing"])
    return out


def z0_median(cls):
    """Медиана z0 растра по классам configs/surface_heat.json (порядок ключей = номер класса)."""
    cl = json.load(open(CONFIGS / "surface_heat.json"))["classes"]
    z0 = np.array([c["z0_m"] for c in cl.values()])
    return float(np.median(z0[cls.ravel()])), list(cl.keys())


def window_domain(dx, cx, cy, n=N_WINDOW):
    half = 0.5 * n * dx
    return dict(x0=round((cx - half) / CORNER_STEP) * CORNER_STEP, y0=round((cy - half) / CORNER_STEP) * CORNER_STEP,
                nx=n, ny=n, dx=dx)


def window_vertical(hc, dx):
    dz = dx / 2.0
    lo, hi = float(np.min(hc)), float(np.max(hc))
    z_bot = np.floor(lo / dz) * dz - dz
    nz = int(np.ceil((hi + TOP_ABOVE - z_bot) / dz))
    nz += nz % 2
    return dz, z_bot, nz


def block_mean(g, dom):
    """Среднее высот узлов 25 м в клетке (weather_core::block_mean), (ny, nx), строка j на север."""
    f = int(round(dom["dx"] / CORNER_STEP))
    xs = dom["x0"] + CORNER_STEP * np.arange(f * dom["nx"])
    ys = dom["y0"] + CORNER_STEP * np.arange(f * dom["ny"])
    ix = np.rint((xs - g["x"][0]) / g["spacing"]).astype(int)
    iy = np.rint((ys - g["y"][0]) / g["spacing"]).astype(int)
    h = g["z"][np.ix_(iy, ix)]
    return h.reshape(dom["ny"], f, dom["nx"], f).mean(axis=(1, 3))


def window_points(g, dx, centre):
    """Центры клеток окна: (X, Y, Z) плоские, форма (nz, ny, nx), и dict с параметрами окна."""
    dom = window_domain(dx, *centre)
    hc = block_mean(g, dom)
    dz, z_bot, nz = window_vertical(hc, dx)
    xc = dom["x0"] + (np.arange(dom["nx"]) + 0.5) * dx
    yc = dom["y0"] + (np.arange(dom["ny"]) + 0.5) * dx
    zc = z_bot + (np.arange(1, nz + 1) - 0.5) * dz
    Z, Y, X = np.meshgrid(zc, yc, xc, indexing="ij")
    info = dict(dom=dom, nz=nz, dz=dz, z_bot=z_bot, hc_min=float(hc.min()), hc_max=float(hc.max()))
    return X, Y, Z, info
