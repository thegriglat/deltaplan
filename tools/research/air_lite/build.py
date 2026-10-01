#!/usr/bin/env python3
"""Набор точек для суррогата: признаки (features.py) + целевые величины полных решений (gen.py).

По каждому окну 100 м каждого случая: столбцы внутри окна (без 5 клеток у края — зона релаксации
к родителю), высоты AGL 25…2000 м. Целевые величины:
  механика (решение без нагрева, только U10 ≥ 0,5 м/с), в долях фона Ubg(a):
    t_mpar — вдоль ветра, t_mper — поперёк (влево), t_mw — w_mech;
  нагрев (решение с нагревом минус без), м/с и К:
    t_cpar, t_cper — добавка горизонтали (вдоль ветра, влево), t_cw — w_conv, t_th — θ′.
Для обучения — случайные 300 столбцов окна × все высоты (out/ds_points.npz); полные окна для ключевых
чисел пересобираются в evaluate.py.

  .venv/bin/python build.py            # → out/ds_points.npz
"""
from __future__ import annotations

import json
import math
from functools import lru_cache
from pathlib import Path

import numpy as np

import features as F
import places as P
import real as R
import weather as W

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
FIELDS = HERE / "fields"
AGL_ALL = (25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000)
AGL_FIT = AGL_ALL
EDGE = 5
U_MIN = 0.5


def load_runs(path=OUT / "runs.jsonl"):
    rows = []
    for line in Path(path).read_text().splitlines():
        r = json.loads(line)
        if r.get("status") == "ok":
            rows.append(r)
    return rows


@lru_cache(maxsize=4096)
def day_for(loc, hour, t_max, sky):
    return W.Day(hour, t_max, sky, P.context(loc))


def window_frame(run, iw, Z, agl_idx=None):
    """Признаки и цели полного окна iw случая run → (feats: dict имя → (nA, ny, nx), targ: dict, aux)."""
    m = run[f"w{iw}"]
    loc = run["loc"]
    agl = np.array(AGL_ALL if agl_idx is None else [AGL_ALL[i] for i in agl_idx], float)
    ia = list(range(len(AGL_ALL))) if agl_idx is None else list(agl_idx)
    nx, ny, dx = m["nx"], m["ny"], m["dx"]
    hc = Z[f"w{iw}_hc"].astype(np.float64)
    H = Z[f"w{iw}_H"].astype(np.float64)
    hbl = Z[f"w{iw}_hbl"].astype(np.float64)
    st = F.column_static(loc, m["x0"], m["y0"], dx, nx, ny)
    X, Y = st["_X"], st["_Y"]
    U10, wdir = run["U10"], run["wdir"]
    wf = F.column_wind(loc, X, Y, wdir if U10 > 0 else 0.0)
    pr = run["profile"]
    D = day_for(loc, run["hour"], run["t_max"], run["sky"])
    zg = float(np.median(hc))
    N = F.n_eff(D, zg)
    Ub = F.ubg(agl, pr["alpha"], pr["max_profile"], U10)
    U500 = float(F.ubg(np.array([500.0]), pr["alpha"], pr["max_profile"], U10)[0])
    pf, x0, y0, d = F.potential_flow(loc, wdir if U10 > 0 else 0.0, 0.0, 1.0, tuple(agl))
    ws, _, _, _ = F.potential_flow(loc, wdir if U10 > 0 else 0.0, N, max(U500, 0.5), tuple(agl))
    nA = len(agl)
    feats = {}
    sh = (nA, ny, nx)
    bc = lambda a: np.broadcast_to(a, sh).astype(np.float32)
    for k, v in st.items():
        if not k.startswith("_"):
            feats[k] = bc(v[None])
    for k, v in wf.items():
        feats[k] = bc(v[None])
    for c, name in enumerate(("pf_u", "pf_v", "pf_w")):
        feats[name] = np.stack([F.sample_grid(pf[c, i], x0, y0, d, X, Y) for i in range(nA)]).astype(np.float32)
    for c, name in ((0, "ws_u"), (2, "ws_w")):
        feats[name] = np.stack([F.sample_grid(ws[c, i], x0, y0, d, X, Y) for i in range(nA)]).astype(np.float32)
    feats["a"] = bc(agl[:, None, None])
    feats["Ub"] = bc(Ub[:, None, None])
    feats["U10"] = bc(np.float32(U10))
    feats["alpha"] = bc(np.float32(pr["alpha"]))
    feats["N"] = bc(np.float32(N))
    feats["hbl"] = bc(hbl[None])
    feats["zi_agl"] = bc((D.z_i - hc)[None])
    feats["H"] = bc(H[None])
    from scipy.ndimage import gaussian_filter
    feats["H_s1500"] = bc(gaussian_filter(H, 15.0, mode="nearest")[None])
    feats["H_s500"] = bc(gaussian_filter(H, 5.0, mode="nearest")[None])
    feats["sun_el"] = bc(np.float32(pr["sun_el"]))
    feats["hour"] = bc(np.float32(run["hour"]))
    feats["sky_heat"] = bc(np.float32(D.sky_heat))
    feats["t_max"] = bc(np.float32(run["t_max"]))
    # цели
    hh = Z[f"w{iw}_h"][:, ia].astype(np.float64)
    mm = Z[f"w{iw}_m"][:, ia].astype(np.float64)
    ex, ey = F.unit(wdir if U10 > 0 else 0.0)     # штиль — та же система, что у признаков (ветер «с севера»)
    targ = {}
    if U10 >= U_MIN:
        ub = Ub[:, None, None]
        targ["t_mpar"] = (mm[0] * ex + mm[1] * ey) / ub
        targ["t_mper"] = (-mm[0] * ey + mm[1] * ex) / ub
        targ["t_mw"] = mm[2] / ub
    du, dv = hh[0] - mm[0], hh[1] - mm[1]
    targ["t_cpar"] = du * ex + dv * ey
    targ["t_cper"] = -du * ey + dv * ex
    targ["t_cw"] = hh[2] - mm[2]
    targ["t_th"] = hh[3]
    aux = dict(hh=hh, mm=mm, hc=hc, H=H, X=X, Y=Y, agl=agl, Ub=Ub, ex=ex, ey=ey, day=D, N=N)
    return feats, targ, aux


_RUNS, _PLAN = None, None


def _one(args):
    ir, n_cols, seed = args
    run = _RUNS[ir]
    rng = np.random.default_rng(seed * 100003 + ir)
    agl_idx = [AGL_ALL.index(a) for a in AGL_FIT]
    Z = np.load(FIELDS / f"{run['id']}.npz")
    cols = {}
    for iw in range(len(_PLAN["centers"][run["loc"]])):
        if f"w{iw}" not in run:
            continue
        feats, targ, aux = window_frame(run, iw, Z, agl_idx)
        nA, ny, nx = feats["a"].shape
        jj = rng.integers(EDGE, ny - EDGE, n_cols)
        ii = rng.integers(EDGE, nx - EDGE, n_cols)
        sel = lambda A: A[:, jj, ii].ravel()
        for k, v in feats.items():
            cols.setdefault(k, []).append(sel(v).astype(np.float32))
        for k in TARGETS:
            v = targ.get(k)
            cols.setdefault(k, []).append(sel(v).astype(np.float32) if v is not None
                                          else np.full(nA * n_cols, np.nan, np.float32))
        n = nA * n_cols
        cols.setdefault("case", []).append(np.full(n, ir, np.int32))
        cols.setdefault("win", []).append(np.full(n, iw, np.int16))
    return {k: np.concatenate(v) for k, v in cols.items()}


TARGETS = ("t_mpar", "t_mper", "t_mw", "t_cpar", "t_cper", "t_cw", "t_th")


def main(n_cols=300, seed=1, procs=12):
    global _RUNS, _PLAN
    import multiprocessing as mp
    _RUNS = load_runs()
    _PLAN = json.loads((OUT / "plan.json").read_text())
    with mp.get_context("fork").Pool(procs) as pool:
        parts = pool.map(_one, [(ir, n_cols, seed) for ir in range(len(_RUNS))], chunksize=4)
    data = {k: np.concatenate([p[k] for p in parts]) for k in parts[0]}
    runs = _RUNS
    np.savez_compressed(OUT / "ds_points.npz", **data, case_loc=np.array([r["loc"] for r in runs]),
                        case_id=np.array([r["id"] for r in runs]))
    print("точек:", len(data["a"]), "признаков:", len([k for k in data if not k.startswith("t_")]))


if __name__ == "__main__":
    main()
