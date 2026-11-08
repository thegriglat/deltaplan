"""SWG-4: счёт следа на плотных точках SWG1 и мачтах (группами фокуса, как SWG-1) → out/swg-4/raw/.

  py -m wake.run grids            # решётки δ* (триггер slope) и Хед со следом (триггер head) → raw/grid_<case>.json
  py -m wake.run points           # s по вариантам в точках → raw/pts_<case>.json
  py -m wake.run assemble         # ground.json (SWG2) + tables.md
Каждая стадия пропускает готовое (--force — пересчитать). Один скрипт на всю пачку: py -m wake.run all.
"""
from __future__ import annotations

import json
import sys
import time

import h5py
import numpy as np

from ground import common as K
from ground import evaluate as E
from ground import model as M
from ground import head as GH

from . import core as W

OUT = K.SG / "out" / "swg-4"
RAW = OUT / "raw"
HEAD_DS = 50.0          # сетка для Хеда — как SWG-1 head (ds_min 50 м, фокус во всех точках)


def jdump(path, d):
    K.dump_json(path, d)


def wind(case):
    with h5py.File(K.REFS / f"{case}.h5", "r") as h:
        return np.array(h.attrs["wind_to"], float)


def picard_upar(case, x, y, z_agl=10.0):
    """u∥/|U| Пикара nom (ближайшая клетка, уровень z_agl): < 0 — обратное течение (отрыв у Пикара)."""
    e = wind(case)
    e = e / np.hypot(*e)
    with h5py.File(K.REFS / f"{case}.h5", "r") as h:
        g = h["picard_nom"]
        xs, ys, zl = g["x"][:], g["y"][:], g["z_agl"][:]
        k = int(np.argmin(np.abs(zl - z_agl)))
        sc, off = float(g["u"].attrs["scale"]), float(g["u"].attrs["offset"])
        U = g["u"][k].astype(float) * sc + off
        V = g["v"][k].astype(float) * sc + off
    i = np.clip(np.rint((np.asarray(x) - xs[0]) / (xs[1] - xs[0])).astype(int), 0, xs.size - 1)
    j = np.clip(np.rint((np.asarray(y) - ys[0]) / (ys[1] - ys[0])).astype(int), 0, ys.size - 1)
    u, v = U[j, i], V[j, i]
    return (u * e[0] + v * e[1]) / np.maximum(np.hypot(u, v), 1e-9), (u * e[0] + v * e[1])


def make_grid(case, gate="slope", sep_xy=None):
    run_t, wt = M.C.load_terrain(case, M.C.SMOOTH_MAIN)
    sep_fn = None
    if gate == "head":
        pts = np.asarray(sep_xy, float).reshape(-1, 2)

        def sep_fn(x, y):
            if pts.shape[0] == 0:
                return np.zeros(np.shape(x), bool)
            d2 = (np.asarray(x)[:, None] - pts[None, :, 0]) ** 2 + (np.asarray(y)[:, None] - pts[None, :, 1]) ** 2
            return d2.min(1) <= GH.COVER_R ** 2
    return W.WakeGrid(run_t, wt, M.C.DS_MAIN, gate=gate, sep_fn=sep_fn)


def seg_stats(case, grid):
    """Сводка по подветренным отрезкам: число, со следом, у скольких из них у Пикара на 10 м есть обратное течение."""
    segs = grid.segs
    gated = [g for g in segs if g["gated"]]
    rev = []
    for g in gated:
        n = max(3, int((g["s_r"] - g["s_s"]) / 25.0))
        tt = np.linspace(0, 1, n)
        x = g["x_c"] + tt * (g["x_r"] - g["x_c"])
        y = g["y_c"] + tt * (g["y_r"] - g["y_c"])
        _, up = picard_upar(case, x, y, 10.0)
        rev.append(bool(np.any(up < 0)))
    return dict(n_lines=len({g["c"] for g in segs}), n_segs=len(segs), n_gated=len(gated),
                frac_gated_picard_reverse=float(np.mean(rev)) if rev else None,
                dmax_median=float(np.median([g["dmax"] for g in gated])) if gated else None,
                slope_median_gated=float(np.median([g["slope"] for g in gated])) if gated else None)


def cmd_grids(force=False):
    refs = E.load_refs()
    pts = json.load(open(K.OUT_POINTS))
    for case in K.CASES:
        f = RAW / f"grid_{case}.json"
        if f.exists() and not force:
            continue
        t0 = time.time()
        g_slope = make_grid(case, "slope")
        # Хед по скоростям со следом: сетка ds_min 50 м с фокусом во всех точках (как SWG-1 head), поле = потенциал + σ_w
        pl = E.case_points(case, refs, pts)
        xy = sorted({(p["x"], p["y"]) for p in pl})
        nm = refs["norm"][case]
        run = M.GRun(case, xy + [(nm["x"], nm["y"])], ds_min=HEAD_DS, focus_r_mul=1.0)
        res_pot = W.separation3d_wrap(run, None)
        sig_w, info = W.wake_sigma(run, g_slope)
        res_w = W.separation3d_wrap(run, sig_w)
        run.free()
        run.panels._geom = None
        sep_xy = np.stack([res_w["points"]["x"], res_w["points"]["y"]], 1) if len(res_w["points"]["x"]) else np.zeros((0, 2))
        g_head = make_grid(case, "head", sep_xy)
        jdump(f, dict(case=case, N_head=run.N, n_sep_pot=int(len(res_pot["points"]["x"])),
                      n_sep_wake=int(len(res_w["points"]["x"])), sep_xy=sep_xy.tolist(),
                      sep_pot_xy=np.stack([res_pot["points"]["x"], res_pot["points"]["y"]], 1).tolist()
                      if len(res_pot["points"]["x"]) else [],
                      head_iters=[{k: v for k, v in it.items()} for it in info["iters"]],
                      slope=seg_stats(case, g_slope), head=seg_stats(case, g_head),
                      segs_slope=[{k: v for k, v in g.items()} for g in g_slope.segs if g["gated"]],
                      t_s=time.time() - t0))
        print(case, "грид", f"{time.time() - t0:.0f} с", "отрывов Хеда: потенциал", len(res_pot["points"]["x"]),
              "со следом", len(res_w["points"]["x"]), flush=True)


def load_grids(case):
    d = json.load(open(RAW / f"grid_{case}.json"))
    return {"slope": make_grid(case, "slope"), "head": make_grid(case, "head", d["sep_xy"])}


def cmd_points(force=False, nmax=40):
    refs = E.load_refs()
    pts = json.load(open(K.OUT_POINTS))
    for case in K.CASES:
        f = RAW / f"pts_{case}.json"
        if f.exists() and not force:
            continue
        t0 = time.time()
        grids = load_grids(case)
        pl = E.case_points(case, refs, pts)
        nm = refs["norm"][case]
        ng, gid = E.kd_groups(pl, nmax)
        n = len(pl)
        keys = ["s_pot", "s_jh"] + [f"s_{v}" for v in grids] + [f"s_{v}_prev" for v in grids] + \
               [f"dstar_{v}" for v in grids] + [f"dSw_{v}" for v in grids] + [f"spw_{v}" for v in grids] + ["A", "dS"]
        res = {k: np.full(n, np.nan) for k in keys}
        groups = []
        for g in range(ng):
            sel = [i for i in range(n) if gid[i] == g]
            xy = [(pl[i]["x"], pl[i]["y"]) for i in sel] + [(nm["x"], nm["y"])]
            run = M.GRun(case, xy)
            X = np.array([pl[i]["x"] for i in sel] + [nm["x"]])
            Y = np.array([pl[i]["y"] for i in sel] + [nm["y"]])
            Z = np.array([pl[i]["z_agl"] for i in sel] + [nm["z_agl"]])
            Xa, Ya, Za = run.abs_points(X, Y, Z)
            p = M.jh_parts(run, Xa, Ya, Za)
            res["s_pot"][sel] = p["pot_speed"][:-1] / p["pot_speed"][-1]
            res["s_jh"][sel] = p["speed"][:-1] / p["speed"][-1]
            res["A"][sel] = p["A"][:-1]
            res["dS"][sel] = p["dS"][:-1]
            ginfo = dict(N=run.N, n=len(sel))
            for v, grid in grids.items():
                sig_w, info = W.wake_sigma(run, grid)
                if info["n_wake_panels"] == 0:
                    pw = W.wake_parts(run, Xa, Ya, Za, sig_w)
                    pw_prev = pw
                else:
                    pw = W.wake_parts(run, Xa, Ya, Za, sig_w)
                    pw_prev = W.wake_parts(run, Xa, Ya, Za, info["sigs"][-2]) if len(info["sigs"]) > 1 else pw
                res[f"s_{v}"][sel] = pw["speed"][:-1] / pw["speed"][-1]
                res[f"s_{v}_prev"][sel] = pw_prev["speed"][:-1] / pw_prev["speed"][-1]
                res[f"spw_{v}"][sel] = pw["potw_speed"][:-1] / pw["potw_speed"][-1]
                res[f"dstar_{v}"][sel] = grid.dstar(X[:-1], Y[:-1])
                res[f"dSw_{v}"][sel] = pw["dS_w"][:-1]
                ginfo[v] = dict(n_wake_panels=info["n_wake_panels"], iters=info["iters"],
                                norm_ratio=float(pw["speed"][-1] / p["speed"][-1]))
            groups.append(ginfo)
            run.free()
            run.panels._geom = None
            print(case, f"группа {g + 1}/{ng}", "N", run.N, f"{time.time() - t0:.0f} с", flush=True)
        out = {k: [None if not np.isfinite(x) else float(x) for x in a] for k, a in res.items()}
        out["ids"] = [p["id"] for p in pl]
        out["groups"] = groups
        out["t_s"] = time.time() - t0
        jdump(f, out)


if __name__ == "__main__":
    args = sys.argv[1:]
    force = "--force" in args
    args = [a for a in args if a != "--force"]
    cmd = args[0] if args else ""
    if cmd in ("grids", "all"):
        cmd_grids(force)
    if cmd in ("points", "all"):
        cmd_points(force)
    if cmd in ("assemble", "all"):
        from . import assemble as A
        A.main()
    if cmd not in ("grids", "points", "assemble", "all"):
        print(__doc__)
