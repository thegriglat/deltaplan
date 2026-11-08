"""SWG-3: время поля панелей 3D на сетке окна игры (64×64×nz, шаг 100/50 м) на рельефе Онгудая.

Один запуск = один свежий процесс = одно повторение: холодный старт (рельеф → панели → сборка → LU → решение → всё поле)
и затем пересчёт при смене ветра (+30°, скорость ×1.2; матрица и LU те же).
  panels_timing.py <dx> <method> <rep> <out.json> [--ds-mul 1.0]
  method: panels (velocity_jh) | panels_rotor (rotor_vortex + velocity_rotor)
"""
import argparse
import json
import math
import subprocess
import sys
import time

import numpy as np

import window_grid as W

U10_COLD, U10_CHANGE, DIR_COLD_DEG, DIR_CHANGE_DEG = 7.5, 9.0, 0.0, 30.0   # м/с; направление «куда» от +x, град
SMOOTH_M, Z_SAT, FAR_M, CROP_M = 40.0, 500.0, 10000.0, 10000.0


def bg_log(U10, z0, terrain_sm, wind_to):
    """Логарифмический фон (как compare/core.py: bg_log), z_agl над землёй σ = 250 м; w = 0."""
    ex, ey = wind_to

    def bg(x, y, z):
        x = np.asarray(x, float)
        zagl = np.clip(np.asarray(z, float) - terrain_sm.height(x, np.asarray(y, float)), 0.1 + 3 * z0, Z_SAT)
        U = U10 * np.log(zagl / z0) / math.log(10.0 / z0)
        return U * ex, U * ey, np.zeros_like(U)
    bg.wind_to = (ex, ey)
    bg.kind = "profile"
    return bg


def sync():
    import cupy as cp
    cp.cuda.Stream.null.synchronize()


def gpu_busy():
    try:
        o = subprocess.run(["nvidia-smi", "--query-gpu=utilization.gpu,memory.used", "--format=csv,noheader,nounits"],
                           capture_output=True, text=True).stdout.strip()
        return o
    except Exception:
        return "?"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dx", type=int)
    ap.add_argument("method")
    ap.add_argument("rep", type=int)
    ap.add_argument("out")
    ap.add_argument("--ds-mul", type=float, default=1.0)
    a = ap.parse_args()
    gb0 = gpu_busy()
    T0 = time.perf_counter()
    import cupy as cp
    cp.zeros(1).sum().get()
    t_init = time.perf_counter() - T0                 # контекст CUDA, первая загрузка ядер
    import panels3d as P
    from panels3d import influence as inf
    cx, cz = W.FOCUS_XZ
    centre = (cx, -cz)
    dx = float(a.dx)
    ds_min = dx * a.ds_mul
    parts = {}

    t = time.perf_counter()
    g = W.load_ongudai(CROP_M, centre)
    X, Y, Z, win = W.window_points(g, a.dx, centre)
    z0, _ = W.z0_median(g["cls"])
    T = P.Terrain3D(g["x"], g["y"], g["z"], smooth_m=SMOOTH_M, far_m=FAR_M)
    Tsm = T.smoothed(250.0)
    parts["terrain"] = time.perf_counter() - t

    t = time.perf_counter()
    half = 32 * dx
    step = dx * 8.0
    gx = np.arange(win["dom"]["x0"], win["dom"]["x0"] + 2 * half + 1, step)
    gy = np.arange(win["dom"]["y0"], win["dom"]["y0"] + 2 * half + 1, step)
    focus = [(float(p), float(q)) for p in gx for q in gy]
    panels = P.build_panels(T, focus=focus, ds_min=ds_min, focus_r=0.75 * step)
    parts["mesh"] = time.perf_counter() - t

    t = time.perf_counter()
    infl = P.assemble(panels, "cupy")
    sync()
    parts["assemble"] = time.perf_counter() - t
    t = time.perf_counter()
    infl.lu()
    sync()
    parts["lu"] = time.perf_counter() - t

    def solve_pair(U10, ang_deg):
        """σ для bg и для однородного фона (внутренний слой) — всё, что зависит от ветра, кроме опроса."""
        wt = (math.cos(math.radians(ang_deg)), math.sin(math.radians(ang_deg)))
        t = time.perf_counter()
        bg = bg_log(U10, z0, Tsm, wt)
        tb = time.perf_counter() - t
        t = time.perf_counter()
        sigma, info = P.solve(panels, bg, None, infl)
        U_ref = P.terrain.u_ref_of(bg, T)[0] if hasattr(P, "terrain") else None
        return bg, sigma, wt, tb, time.perf_counter() - t

    from panels3d.terrain import u_ref_of
    pts = (X.ravel(), Y.ravel(), Z.ravel())
    n_pts = pts[0].size

    def stage(U10, ang_deg):
        pr = {}
        wt = (math.cos(math.radians(ang_deg)), math.sin(math.radians(ang_deg)))
        t = time.perf_counter()
        bg = bg_log(U10, z0, Tsm, wt)
        pr["bg"] = time.perf_counter() - t
        t = time.perf_counter()
        sigma, info = P.solve(panels, bg, None, infl)
        U_ref, _ = u_ref_of(bg, T)
        key = ("uniform", float(U_ref), round(wt[0], 12), round(wt[1], 12))
        infl._cache[key] = P.solve(panels, P.bg_uniform(U_ref, wt), None, infl)[0]
        pr["solve"] = time.perf_counter() - t
        pure_t = None
        fil = None
        if a.method == "panels_rotor":
            from rotor3d import rotor_vortex, velocity_rotor
            t = time.perf_counter()
            fil, sigma_r, rinfo = rotor_vortex(panels, bg, z0, infl)
            pr["rotor"] = time.perf_counter() - t
            pr["rotor_placed"] = sum(1 for r in rinfo["ridges"] if r["placed"])
            pr["rotor_ridges"] = rinfo["n_ridges"]
            pr["rotor_candidates"] = len(rinfo["candidates"])
        t = time.perf_counter()
        if a.method == "panels_rotor" and pr["rotor_placed"] > 0:
            u, v, w = velocity_rotor(panels, sigma_r, bg, fil, *pts, z0, infl=infl)
        else:
            u, v, w = P.velocity_jh(panels, sigma, bg, *pts, z0, infl=infl)
        sync()
        pr["query_jh"] = time.perf_counter() - t
        if a.method == "panels":
            t = time.perf_counter()
            P.velocity(panels, sigma, bg, *pts)
            sync()
            pure_t = time.perf_counter() - t
        sp = np.hypot(u, v)
        pr["under_frac"] = float(np.mean(~np.isfinite(sp)))
        pr["umax"] = float(np.nanmax(sp))
        pr["umean"] = float(np.nanmean(sp))
        return pr, pure_t, info

    rows = []
    t_stage = time.perf_counter()
    pr, pure, info = stage(U10_COLD, DIR_COLD_DEG)
    t_cold = t_init + sum(parts.values()) + (time.perf_counter() - t_stage)
    cold_parts = dict(gpu_init=t_init, **parts, **{k: v for k, v in pr.items() if k in ("bg", "solve", "rotor", "query_jh")})
    rows.append(dict(stage="cold", t_total_s=t_cold, parts=cold_parts, pure=pure, extra=pr, residual=info["residual"]))

    t_stage = time.perf_counter()
    pr2, pure2, info2 = stage(U10_CHANGE, DIR_CHANGE_DEG)
    t_wc = time.perf_counter() - t_stage
    rows.append(dict(stage="wind_change", t_total_s=t_wc, parts={k: v for k, v in pr2.items() if k in ("bg", "solve", "rotor", "query_jh")},
                     pure=pure2, extra=pr2, residual=info2["residual"]))
    res = dict(dx=a.dx, method=a.method, rep=a.rep, N_panels=int(panels.N), ds_min=ds_min, n_points=int(n_pts),
               nx=win["dom"]["nx"], ny=win["dom"]["ny"], nz=win["nz"], z0=z0, mem_gb=infl.mem_bytes / 1e9,
               gpu_before=gb0, gpu_after=gpu_busy(), rows=rows)
    json.dump(res, open(a.out, "w"), indent=1)
    print(a.dx, a.method, a.rep, "N", panels.N, "cold %.1f wc %.1f" % (t_cold, t_wc), {k: round(v, 2) for k, v in cold_parts.items()}, flush=True)


if __name__ == "__main__":
    main()
