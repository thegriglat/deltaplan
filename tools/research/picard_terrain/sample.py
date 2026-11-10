"""PT5 v1: выборка поля R4 в точках случая PT1.

  probe_values(case_json, state_json) -> [{name, z_agl, S, u, v, w}]

Правило (одно для базы и всех вариантов):
  * скорость в центре клетки - среднее двух граней по каждой оси (грань земли, тип 0, - 0);
  * колонна (i, j) - клетки воздуха (cell == 1) с центром не ниже рельефа подсетки h(x_i, y_j) (растр PT1, билинейно);
    z_agl = z_k - h(x_i, y_j); значение колонны на z_agl - линейно по z_agl, ниже центра нижней такой клетки - её значение;
  * в точке - билинейно по 4 колоннам на заданном z_agl; S = sqrt(u^2 + v^2) в центре (горизонтальный модуль),
    интерполируется отдельно от u, v (S - выпуклая комбинация значений колонн).
Зависимости: numpy, h5py. Только чтение: ничего не пишется.

  python3 sample.py <case.json> <state.json>      # печатает таблицу
"""
from __future__ import annotations

import json
import os
import sys
from pathlib import Path

import numpy as np


def data_dir():
    return Path(os.environ.get("PICARD_TERRAIN_DATA", "~/data/picard_terrain")).expanduser()


def read_arrays(json_path, meta, names):
    """Массивы float32 из .bin рядом с .json (np.memmap), форма (NZ, NY, NX)."""
    nx, ny, nz = meta["dims"]
    mm = np.memmap(Path(json_path).with_suffix(".bin"), dtype="<f4", mode="r")
    out = {}
    for n in names:
        off, ln = meta["arrays"][n]
        if ln != nx * ny * nz:
            raise ValueError(f"{n}: length {ln} != {nx * ny * nz}")
        out[n] = np.asarray(mm[off:off + ln]).reshape(nz, ny, nx)
    return out


class Raster:
    """Растр подсетки PT1: узлы x0 + i*dx, y0 + j*dx; билинейно, за краем - ближайший узел."""

    def __init__(self, h5path, dataset="h"):
        import h5py
        with h5py.File(h5path, "r") as f:
            ds = f[dataset]
            self.h = np.asarray(ds[...], np.float64)
            self.x0, self.y0, self.dx = float(ds.attrs["x0"]), float(ds.attrs["y0"]), float(ds.attrs["dx"])

    def __call__(self, x, y):
        ny, nx = self.h.shape
        fi = np.clip((np.asarray(x, float) - self.x0) / self.dx, 0, nx - 1.000001)
        fj = np.clip((np.asarray(y, float) - self.y0) / self.dx, 0, ny - 1.000001)
        i0, j0 = np.floor(fi).astype(int), np.floor(fj).astype(int)
        a, b = fi - i0, fj - j0
        h = self.h
        return (1 - b) * ((1 - a) * h[j0, i0] + a * h[j0, i0 + 1]) + b * ((1 - a) * h[j0 + 1, i0] + a * h[j0 + 1, i0 + 1])


def cell_centered(F, T, axis):
    """Значение в центре клетки: среднее двух граней по оси (0 - k, 1 - j, 2 - i); грань типа 0 (земля) даёт 0.
    Последний слой (ореол) остаётся 0."""
    A = np.where(T == 0, 0.0, F)
    out = np.zeros_like(A)
    sl0 = [slice(None)] * 3
    sl1 = [slice(None)] * 3
    sl0[axis], sl1[axis] = slice(0, -1), slice(1, None)
    out[tuple(sl0)] = 0.5 * (A[tuple(sl0)] + A[tuple(sl1)])
    return out


def load_centers(case_json, state_json):
    """-> (meta, state_meta, cell, uc, vc, wc), массивы (NZ, NY, NX) с ореолом."""
    meta = json.loads(Path(case_json).read_text())
    sm = json.loads(Path(state_json).read_text())
    if sm.get("format") != "picard-rs-state" or sm.get("version") != 2 or sm["dims"] != meta["dims"]:
        raise ValueError("state is not R4 v2 of this case grid")
    C = read_arrays(case_json, meta, ["cell", "tu", "tv", "tw"])
    S = read_arrays(state_json, sm, ["u", "v", "w"])
    uc = cell_centered(S["u"], C["tu"], 2)
    vc = cell_centered(S["v"], C["tv"], 1)
    wc = cell_centered(S["w"], C["tw"], 0)
    m = C["cell"] == 1
    return meta, sm, m, uc * m, vc * m, wc * m


def column_profiles(meta, raster, cellmask, fields, ii, jj):
    """Профиль колонны (ii, jj) (индексы с ореолом): (z_agl[k], [поля по k]) для клеток воздуха не ниже рельефа."""
    nx, ny, nz = meta["dims"]
    dx, dz = meta["dx"], meta["dz"]
    xi = meta["x0"] + (ii - 0.5) * dx
    yj = meta["y0"] + (jj - 0.5) * dx
    h = float(raster(xi, yj))
    zc = meta["z_bot"] + (np.arange(nz) - 0.5) * dz
    ok = cellmask[:, jj, ii] & (zc >= h)
    ok[0] = False
    ok[-1] = False
    k = np.where(ok)[0]
    if k.size == 0:
        raise ValueError(f"column ({ii},{jj}) has no air cell above the terrain")
    return zc[k] - h, [f[k, jj, ii] for f in fields]


class ModelGround:
    """Земля модели (старое правило, только для сверки с primer): блочное среднее `hc` клеток, билинейно между центрами."""

    def __init__(self, case_json, meta):
        off, ln = meta["arrays"]["hc"]
        mm = np.memmap(Path(case_json).with_suffix(".bin"), dtype="<f4", mode="r")
        self.h = np.asarray(mm[off:off + ln], np.float64).reshape(meta["ny"], meta["nx"])
        self.x0, self.y0, self.dx = meta["x0"] + meta["dx"] / 2, meta["y0"] + meta["dx"] / 2, meta["dx"]

    __call__ = Raster.__call__


def probe_values(case_json, state_json, probes=None, ground="raster"):
    """Значения [{name, z_agl, S, u, v, w}] в точках `pt.probes` случая (или в заданных `probes`).
    ground: "raster" - растр подсетки PT1 (правило PT5); "model" - земля модели hc (старое правило, не для строк)."""
    meta, sm, mask, uc, vc, wc = load_centers(case_json, state_json)
    pt = meta["pt"]
    t = pt["terrain"]
    raster = Raster(data_dir() / t["path"], t["dataset"]) if ground == "raster" else ModelGround(case_json, meta)
    nx, ny, nz = meta["dims"]
    dx = meta["dx"]
    Sc = np.sqrt(uc ** 2 + vc ** 2)
    out = []
    for p in (probes if probes is not None else pt["probes"]):
        fi = np.clip((p["x"] - meta["x0"]) / dx + 0.5, 1.0, nx - 2 + 1e-9)
        fj = np.clip((p["y"] - meta["y0"]) / dx + 0.5, 1.0, ny - 2 + 1e-9)
        i0, j0 = int(np.floor(fi)), int(np.floor(fj))
        i0, j0 = min(i0, nx - 3), min(j0, ny - 3)
        a, b = fi - i0, fj - j0
        acc = np.zeros(4)
        for dj, wj in ((0, 1 - b), (1, b)):
            for di, wi in ((0, 1 - a), (1, a)):
                za, fl = column_profiles(meta, raster, mask, [Sc, uc, vc, wc], i0 + di, j0 + dj)
                acc += wj * wi * np.array([np.interp(p["z_agl"], za, f) for f in fl])
        out.append(dict(name=p["name"], z_agl=float(p["z_agl"]), S=float(acc[0]), u=float(acc[1]), v=float(acc[2]), w=float(acc[3])))
    return out


def dS(case_json, values):
    """dS = S/S_pair - 1 по полю `pair` точек `target` (иначе None). -> {name: dS | None}."""
    pt = json.loads(Path(case_json).read_text())["pt"]
    S = {v["name"]: v["S"] for v in values}
    return {p["name"]: (S[p["name"]] / S[p["pair"]] - 1.0 if p.get("pair") else None) for p in pt["probes"]}


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    vals = probe_values(sys.argv[1], sys.argv[2])
    d = dS(sys.argv[1], vals)
    for v in vals:
        print(f"{v['name']:14s} z_agl {v['z_agl']:6.1f}  S {v['S']:7.3f}  u {v['u']:7.3f} v {v['v']:7.3f} w {v['w']:7.3f}"
              + ("" if d[v['name']] is None else f"  dS {d[v['name']]:+.3f}"))
