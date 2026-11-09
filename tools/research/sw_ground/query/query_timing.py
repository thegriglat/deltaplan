"""SWG-6: время поля панелей 3D на окне игры с рычагами опроса (один запуск = один свежий процесс = одно повторение).
  query_timing.py <dx> <variant> <rep> <out.json> [--raw DIR]
Стадии как в SWG-3 (timing/panels_timing.py): cold (процесс → CUDA → рельеф → панели → сборка → LU → решение → поле) и
wind_change (+30°, 7,5 → 9 м/с, матрица и LU те же). variant — ключ VARIANTS. Эталон ошибки — fp64 (элементный CuPy, как
SWG-3) на надземных точках: `raw/ref_<dx>_<stage>.npz`, пишет первый запуск variant 'above_ground' (rep 0).
"""
import argparse
import json
import math
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "timing"))
sys.path.insert(0, HERE)
import window_grid as W            # noqa: E402  (SWG-3, не менять)
import panels_timing as PT         # noqa: E402
import fastq                       # noqa: E402

THETA = 0.5          # выбран до замера: стандартный Барнс–Хат; 0,3 и 0,7 — для зависимости ошибки от θ
STRIDE = 2           # vert_interp: каждый 2-й уровень выше 300 м над землёй
AGL_INTERP = 300.0
VARIANTS = {
    "above_ground": dict(prec=None, theta=None, above=True, vi=0),
    "vert_interp": dict(prec=None, theta=None, above=True, vi=STRIDE),
    "fp32": dict(prec="f32", theta=None, above=False, vi=0),
    "fused64": dict(prec="f64", theta=None, above=False, vi=0),
    "far_cluster": dict(prec="f64", theta=THETA, above=False, vi=0),
    "far_cluster_t03": dict(prec="f64", theta=0.3, above=False, vi=0),
    "far_cluster_t07": dict(prec="f64", theta=0.7, above=False, vi=0),
    "fp32+above_ground": dict(prec="f32", theta=None, above=True, vi=0),
    "fp32+above_ground+vert_interp": dict(prec="f32", theta=None, above=True, vi=STRIDE),
    "fp32+above_ground+far_cluster": dict(prec="f32", theta=THETA, above=True, vi=0),
    "fp32+above_ground+far_cluster+vert_interp": dict(prec="f32", theta=THETA, above=True, vi=STRIDE),
}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dx", type=int)
    ap.add_argument("variant")
    ap.add_argument("rep", type=int)
    ap.add_argument("out")
    ap.add_argument("--raw", default=os.path.join(HERE, "..", "out", "swg-6", "raw"))
    a = ap.parse_args()
    cfg = VARIANTS[a.variant]
    gb0 = PT.gpu_busy()
    T0 = time.perf_counter()
    import cupy as cp
    cp.zeros(1).sum().get()
    t_init = time.perf_counter() - T0
    import panels3d as P
    from panels3d import influence as _inf
    _inf._BLOCK = 1_000_000        # блок (точек × панелей) вдвое… втрое меньше SWG-3 (3 000 000): память GPU общая; числа те же
    from panels3d.terrain import u_ref_of
    cx, cz = W.FOCUS_XZ
    centre = (cx, -cz)
    dx = float(a.dx)
    parts = {}

    t = time.perf_counter()
    g = W.load_ongudai(PT.CROP_M, centre)
    X, Y, Z, win = W.window_points(g, a.dx, centre)
    z0, _ = W.z0_median(g["cls"])
    T = P.Terrain3D(g["x"], g["y"], g["z"], smooth_m=PT.SMOOTH_M, far_m=PT.FAR_M)
    Tsm = T.smoothed(250.0)
    parts["terrain"] = time.perf_counter() - t

    t = time.perf_counter()
    half, step = 32 * dx, dx * 8.0
    gx = np.arange(win["dom"]["x0"], win["dom"]["x0"] + 2 * half + 1, step)
    gy = np.arange(win["dom"]["y0"], win["dom"]["y0"] + 2 * half + 1, step)
    focus = [(float(p), float(q)) for p in gx for q in gy]
    panels = P.build_panels(T, focus=focus, ds_min=dx, focus_r=0.75 * step)
    parts["mesh"] = time.perf_counter() - t
    t = time.perf_counter()
    infl = P.assemble(panels, "cupy")
    PT.sync()
    parts["assemble"] = time.perf_counter() - t
    t = time.perf_counter()
    fastq.lu_inplace(infl)       # LU на месте (память GPU общая); подробности — fastq.lu_inplace
    PT.sync()
    parts["lu"] = time.perf_counter() - t

    shp = X.shape
    nz = shp[0]
    Xf, Yf, Zf = X.ravel(), Y.ravel(), Z.ravel()
    n_all = Xf.size
    kidx = np.broadcast_to(np.arange(nz)[:, None, None], shp).ravel()
    dz = win["dz"]

    fq = None
    if cfg["prec"]:
        t = time.perf_counter()
        org = np.array([Xf.mean(), Yf.mean(), Zf.mean()])
        tree = fastq.Tree(panels) if cfg["theta"] else None
        fq = fastq.FastQuery(panels, np.float32 if cfg["prec"] == "f32" else np.float64, cfg["theta"], origin=org,
                             block_m=6.0 * dx, tree=tree)
        parts["query_prep"] = time.perf_counter() - t

    def stage(name, U10, ang_deg):
        pr = {}
        t_st0 = time.perf_counter()
        wt = (math.cos(math.radians(ang_deg)), math.sin(math.radians(ang_deg)))
        t = time.perf_counter()
        bg = PT.bg_log(U10, z0, Tsm, wt)
        pr["bg"] = time.perf_counter() - t
        t = time.perf_counter()
        sigma, info = P.solve(panels, bg, None, infl)
        U_ref, _ = u_ref_of(bg, T)
        infl._cache[("uniform", float(U_ref), round(wt[0], 12), round(wt[1], 12))] = P.solve(panels, P.bg_uniform(U_ref, wt), None, infl)[0]
        pr["solve"] = time.perf_counter() - t

        t = time.perf_counter()
        hg = panels.height(Xf, Yf)
        under = Zf < hg
        sel = np.ones(n_all, bool)
        if cfg["above"]:
            sel &= ~under
        if cfg["vi"]:
            agl = Zf - hg
            skip = (~under) & (agl > AGL_INTERP) & (kidx % cfg["vi"] != 0) & (kidx != nz - 1) & \
                   (agl - (kidx % cfg["vi"]) * dz > AGL_INTERP)
            sel &= ~skip
        idx = np.nonzero(sel)[0]
        pr["select"] = time.perf_counter() - t
        if fq is not None:
            for k in fq.t:
                fq.t[k] = 0
        t = time.perf_counter()
        if fq is not None:
            with fastq.patched(fq):
                u, v, w = P.velocity_jh(panels, sigma, bg, Xf[idx], Yf[idx], Zf[idx], z0, infl=infl)
        else:
            u, v, w = P.velocity_jh(panels, sigma, bg, Xf[idx], Yf[idx], Zf[idx], z0, infl=infl)
        PT.sync()
        pr["query_jh"] = time.perf_counter() - t
        t = time.perf_counter()
        U = np.full(n_all, np.nan)
        V = np.full(n_all, np.nan)
        U[idx], V[idx] = u, v
        if cfg["vi"]:
            s = cfg["vi"]
            k0 = kidx - kidx % s
            k1 = np.minimum(k0 + s, nz - 1)
            sk = np.nonzero(skip)[0]
            f = ((kidx[sk] - k0[sk]) / (k1[sk] - k0[sk])).astype(float)
            i0, i1 = sk - (kidx[sk] - k0[sk]) * (n_all // nz), sk + (k1[sk] - kidx[sk]) * (n_all // nz)
            U[sk] = (1 - f) * U[i0] + f * U[i1]
            V[sk] = (1 - f) * V[i0] + f * V[i1]
        pr["interp"] = time.perf_counter() - t
        pr["t_core"] = time.perf_counter() - t_st0       # без сравнения с эталоном (err) ниже
        pr["n_points_queried"] = int(idx.size)
        if fq is not None:
            pr["kernel"] = fq.t["kernel"]
            pr["lists"] = fq.t["lists"]
            pr["pairs_direct_per_pt"] = fq.t["n_direct"] / max(fq.t["n_pts"], 1)
            pr["nodes_per_pt"] = fq.t["n_cluster"] / max(fq.t["n_pts"], 1)
        above = np.isfinite(U) & ~under
        sp = np.hypot(U, V)
        pr["under_frac"] = float(under.mean())
        pr["umax"] = float(np.nanmax(sp))
        # эталон
        rp = os.path.join(a.raw, f"ref_{a.dx}_{name}.npz")
        err = None
        if a.variant == "above_ground" and a.rep == 0 and not os.path.exists(rp):
            np.savez_compressed(rp, u=U.astype(np.float64), v=V.astype(np.float64))
        if os.path.exists(rp):
            ref = np.load(rp)
            m = ~under
            err = fastq.horizontal_err(U[m], V[m], ref["u"][m], ref["v"][m])
        return pr, info, err

    os.makedirs(a.raw, exist_ok=True)
    rows = []
    pr, info, err = stage("cold", PT.U10_COLD, PT.DIR_COLD_DEG)
    t_cold = t_init + sum(parts.values()) + pr["t_core"]
    cparts = dict(gpu_init=t_init, **parts, **{k: v for k, v in pr.items() if k in ("bg", "solve", "select", "query_jh", "interp", "kernel", "lists")})
    rows.append(dict(stage="cold", t_total_s=t_cold, parts=cparts, extra=pr, residual=None, err=err))
    pr2, info2, err2 = stage("wind_change", PT.U10_CHANGE, PT.DIR_CHANGE_DEG)
    t_wc = pr2["t_core"]
    rows.append(dict(stage="wind_change", t_total_s=t_wc, parts={k: v for k, v in pr2.items() if k in ("bg", "solve", "select", "query_jh", "interp", "kernel", "lists")},
                     extra=pr2, residual=None, err=err2))
    res = dict(dx=a.dx, variant=a.variant, cfg=cfg, rep=a.rep, N_panels=int(panels.N), ds_min=dx, n_points=int(n_all),
               nx=win["dom"]["nx"], ny=win["dom"]["ny"], nz=win["nz"], z0=z0, mem_gb=infl.mem_bytes / 1e9,
               gpu_before=gb0, gpu_after=PT.gpu_busy(), rows=rows)
    json.dump(res, open(a.out, "w"), indent=1)
    print(a.dx, a.variant, a.rep, "N", panels.N, "cold %.1f wc %.1f" % (t_cold, t_wc), "err", err and {k: round(v, 5) for k, v in err.items()},
          {k: round(v, 2) for k, v in cparts.items()}, flush=True)


if __name__ == "__main__":
    main()
