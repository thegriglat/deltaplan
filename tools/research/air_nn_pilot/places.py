"""Места набора: встроенные (configs/locations, слой detail 25 м) и синтетика того же формата.
Перенесено из research/air-lite 7cc7e33 (tools/research/air_lite/places.py); добавлены процедурные рельефы
p_<NNN> (procedural.py) — тот же класс SynthLocation с другой высотой и стартом, всё остальное без изменений;
места t_<NNNN> — вырезки П6 v1 (NN-P4, каталог $AIRNN_P6_DIR или $AIR_NN_DATA/pilot/tiles/v1), класс TerrainLocation.

Синтетика — рельеф 40 × 40 км (1601 × 1601 узлов по 25 м, как detail), база BASE м над морем,
широта/долгота/часовой пояс — как у Онгудая (тот же климат и солнце, июль), долина — по рельефу.
Подменяет `real.location` / `real.context` эталона (air3d), так что всё остальное (сетки, погода,
поток тепла, решатель) идёт тем же путём, что у встроенных мест.

Координаты: x — восток, y — север (= −Z игры), м от центра места.
"""
from __future__ import annotations

import csv
import json
import math
import os
import sys
from functools import lru_cache
from pathlib import Path

import numpy as np

import procedural as PR

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
AIR3D = HERE.parent / "air3d"
sys.path.insert(0, str(AIR3D))

import real as R      # noqa: E402
import terrain as T   # noqa: E402
import weather as W   # noqa: E402

REAL = ("ongudai", "aushkul", "altai", "askarovo")
SYNTH = ("s_ridge", "s_saddle", "s_hill", "s_valley", "s_scarp")
BASE = 1000.0
N_NODES, SP = 1601, 25.0


def _agnesi(x, H, L):
    return H / (1 + (x / L) ** 2)


def _ends(Y, half_len, L):
    return np.exp(-np.maximum(np.abs(Y) - half_len, 0) ** 2 / (2 * L ** 2))


def synth_height(name, X, Y):
    """Высота над базой, м. Хребты — вдоль оси y (север–юг); ветер набора — со всех сторон."""
    if name == "s_ridge":      # одиночный хребет 450 м, полуширина 700 м, длина 12 км (Аньези, как synth.ridge3d)
        return _agnesi(X, 450.0, 700.0) * _ends(Y, 6000.0, 700.0)
    if name == "s_saddle":     # хребет 500 м с седловиной 250 м (synth.saddle3d)
        crest = 500.0 - 250.0 * np.exp(-Y ** 2 / (2 * 400.0 ** 2))
        return crest / (1 + (X / 600.0) ** 2) * _ends(Y, 3500.0, 600.0)
    if name == "s_hill":       # отдельная гора 550 м, L = 900 м (synth.hill3d)
        return 550.0 / (1 + (X ** 2 + Y ** 2) / 900.0 ** 2) ** 1.5
    if name == "s_valley":     # долина между двумя хребтами 600 м в 5 км, длина 14 км
        e = _ends(Y, 7000.0, 900.0)
        return (_agnesi(X - 2500.0, 600.0, 900.0) + _agnesi(X + 2500.0, 600.0, 900.0)) * e
    if name == "s_scarp":      # уступ плато 400 м (tanh, L = 400 м), плато к востоку, 10 км вдоль
        step = 400.0 * 0.5 * (1 + np.tanh(X / 400.0))
        e = _ends(Y, 5000.0, 1500.0) * np.exp(-np.maximum(X - 6000.0, 0) ** 2 / (2 * 2000.0 ** 2))
        return step * e
    raise KeyError(name)


SYNTH_SITES = dict(s_ridge=[(0.0, 0.0)], s_saddle=[(0.0, 0.0)], s_hill=[(0.0, 0.0)], s_valley=[(0.0, 0.0)],
                   s_scarp=[(0.0, 0.0)])


class SynthLocation:
    def __init__(self, name):
        self.id = name
        x = (np.arange(N_NODES) - (N_NODES - 1) / 2) * SP
        X, Y = np.meshgrid(x, x)
        if name.startswith("p_"):     # процедурный рельеф (procedural.py): высота над морем и старт — из параметров
            prm = PR.params(int(name[2:]))
            self.h = PR.height(prm, X, Y)
            sites = [prm["start"]]
        else:
            self.h = BASE + synth_height(name, X, Y)
            sites = SYNTH_SITES[name]
        self.info = dict(spacing=SP, x0=float(x[0]), y0=float(x[0]))
        self.water = None
        self.meta = dict(center_lat=None, center_lon=None)
        self.sites = {f"c{i}": dict(name=f"c{i}", x=p[0], y=p[1], heading=0.0) for i, p in enumerate(sites)}

    def height_at(self, x, z):
        y = -z
        fi = (x - self.info["x0"]) / SP
        fj = (y - self.info["y0"]) / SP
        i0 = int(np.clip(np.floor(fi), 0, N_NODES - 2)); j0 = int(np.clip(np.floor(fj), 0, N_NODES - 2))
        a, b = fi - i0, fj - j0
        h = self.h
        return float((1 - b) * ((1 - a) * h[j0, i0] + a * h[j0, i0 + 1]) + b * ((1 - a) * h[j0 + 1, i0] + a * h[j0 + 1, i0 + 1]))


# ------------------------------------------------------------------------------------------- места t_* (П6 v1)
def p6_dir():
    """Каталог вырезок П6: $AIRNN_P6_DIR, иначе $AIR_NN_DATA/pilot/tiles/v3 (по умолчанию /home/greg/air_nn_data)."""
    d = os.environ.get("AIRNN_P6_DIR")
    if d:
        return Path(d)
    return Path(os.environ.get("AIR_NN_DATA") or "/home/greg/air_nn_data") / "pilot" / "tiles" / "v3"


@lru_cache(maxsize=4)
def p6_index(d=None):
    """index.csv П6 → {id: строка} (числа — float/int, порядок — как в файле)."""
    d = Path(d) if d else p6_dir()
    out = {}
    with open(d / "index.csv", newline="") as f:
        for r in csv.DictReader(f):
            row = dict(r)
            for k in P6_FLOATS:
                row[k] = float(row[k])
            row["zoom"] = int(row["zoom"])
            out[row["id"]] = row
    return out


P6_FLOATS = ("lat", "lon", "src_spacing_m", "h_mean", "h_min", "h_max", "relief_m", "slope_p50", "slope_p95",
             "tpi2k_p95", "sea_frac")


class TerrainLocation:
    """Место t_<NNNN> из вырезки П6 v1 (`cut/<id>.npz`): h — float32 файла, переведённый в float64 (тогда
    `R.grid_domain(loc, 400)` = `hc400` файла побитно — то же блочное среднее), оси [j — север, i — восток],
    узел (800, 800) — центр; x0 = y0 = −20 000 м. Старты — нет (центры окон оценки — window_centers по рельефу),
    вода — нет (границы пилота: озёра в горах — как суша)."""

    def __init__(self, loc):
        d = p6_dir()
        row = p6_index(str(d))[loc]
        with np.load(d / "cut" / f"{loc}.npz") as z:
            h = z["h"]
            self.hc400 = z["hc400"]
            self.cut_meta = json.loads(str(z["meta"]))
        assert h.shape == (N_NODES, N_NODES) and h.dtype == np.float32, (loc, h.shape, h.dtype)
        self.id = loc
        self.h = h.astype(np.float64)
        x0 = -(N_NODES - 1) / 2 * SP
        self.info = dict(spacing=SP, x0=x0, y0=x0)
        self.water = None
        self.meta = dict(center_lat=row["lat"], center_lon=row["lon"])
        self.row = row
        self.sites = {}

    height_at = SynthLocation.height_at


def place_info(loc):
    """Для метаданных случая: system и part из индекса П6 (у прежних мест — None)."""
    if not loc.startswith("t_"):
        return None
    r = p6_index(str(p6_dir()))[loc]
    return dict(system=r["system"], part=r["part"])


# место держит h 1601² float64 (~20 МБ): кэш ограничен (345 мест П6 в память не влезут; счёт идёт по случаям,
# соседние случаи плана обычно с разных мест — повторная загрузка вырезки ~0,1 с против секунд решателя)
@lru_cache(maxsize=8)
def location(loc):
    if loc.startswith("t_"):
        return TerrainLocation(loc)
    return SynthLocation(loc) if loc.startswith(("s_", "p_")) else T.Location(loc)


@lru_cache(maxsize=None)
def context(loc):
    L = location(loc)
    if loc.startswith("t_"):
        # П6 v1: дата reference_context (как у игры), lat/lon места, пояс round(lon/15), окрестность — по рельефу
        rc = W.CFG["reference_context"]
        ctx = dict(month=rc["month"], day=rc["day"], lat=L.meta["center_lat"], lon=L.meta["center_lon"],
                   utc_offset_h=round(L.meta["center_lon"] / 15.0))
        ctx.update(W.ground_context(L.height_at))
        return ctx
    if not loc.startswith(("s_", "p_")):
        return W.location_ctx(loc, L.height_at)
    ref = json.loads((ROOT / "configs/locations/ongudai.json").read_text())
    rc = W.CFG["reference_context"]
    ctx = dict(month=rc["month"], day=rc["day"], lat=ref["center_lat"], lon=ref["center_lon"],
               utc_offset_h=ref.get("utc_offset_h", round(ref["center_lon"] / 15.0)))
    ctx.update(W.ground_context(L.height_at))
    return ctx


# эталон берёт место и контекст через эти функции — подменяем на общие (встроенные + синтетика)
R.location = location
R.context = context


def gauss_smooth(h, sigma_nodes):
    from scipy.ndimage import gaussian_filter
    return gaussian_filter(h, sigma_nodes, mode="nearest")


def window_centers(loc, n_total=1, min_sep=5000.0, lim=12000.0):
    """Центры окон 100 м: старты места + n_extra точек наибольшего превышения над окрестностью 2 км
    (|x|, |y| ≤ lim, не ближе min_sep к уже взятым), всего n_total окон."""
    L = location(loc)
    cs = [(float(s["x"]), float(s["y"])) for s in L.sites.values()]
    # слить почти совпадающие старты (одна гора) — окно 6,4 км их всё равно покрывает
    out = []
    for c in cs:
        if all(math.hypot(c[0] - o[0], c[1] - o[1]) > 3000.0 for o in out):
            out.append(c)
    if len(out) < n_total:
        h = L.h
        f = 8   # 200 м
        hc = h[: (h.shape[0] // f) * f, : (h.shape[1] // f) * f].reshape(h.shape[0] // f, f, h.shape[1] // f, f).mean(axis=(1, 3))
        tpi = hc - gauss_smooth(hc, 2000.0 / (f * SP))
        x = L.info["x0"] + (np.arange(hc.shape[1]) + 0.5) * f * SP
        y = L.info["y0"] + (np.arange(hc.shape[0]) + 0.5) * f * SP
        X, Y = np.meshgrid(x, y)
        ok = (np.abs(X) <= lim) & (np.abs(Y) <= lim)
        order = np.argsort(np.where(ok, tpi, -np.inf), axis=None)[::-1]
        for idx in order:
            j, i = np.unravel_index(idx, tpi.shape)
            p = (float(X[j, i]), float(Y[j, i]))
            if all(math.hypot(p[0] - o[0], p[1] - o[1]) > min_sep for o in out):
                out.append(p)
            if len(out) >= n_total:
                break
    return out
