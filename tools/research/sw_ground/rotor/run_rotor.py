"""SWG-2: нить ротора rotor3d v2 (SWD7) на Perdigão NE/SW и Askervein -> out/swg-2/rotor.json (SWG3 v1).

  tools/research/sw_ground/py tools/research/sw_ground/rotor/run_rotor.py [CASE ...]

Один набор параметров на все случаи (штатные SWD7 v2), панели и фон — основной набор SWD5 (sigma 40 м, ds_min 25 м,
z0 — медиана растра, лог-фон). Критерий ротора — compare/core.py rotor_scan (u∥ < -0,5 м/с на 15 м, отрезок > 50 м).
Пакеты sw_charges_3d только импортируются.
"""
from __future__ import annotations

import json
import math
import os
import subprocess
import sys
import time
from pathlib import Path

import h5py
import numpy as np

HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "out" / "swg-2"
ROOT3D = HERE.parent.parent / "sw_charges_3d"
sys.path.insert(0, str(ROOT3D / "compare"))
import core as C  # noqa: E402
import run_compare as RC  # noqa: E402
import rotor3d  # noqa: E402

PARAMS = {"closure": "reattach", "R_rule": 0.25, "gate": "slope", "slope_min": 0.27}
CRITERION = ("u∥ < -0,5 м/с на z_agl 15 м, отрезок > 50 м вдоль разреза SWD1 (compare/core.py rotor_scan, как SWD5); "
             "u∥ панелей масштабирована к U данных в опорной точке norm; глубина — max z_agl связной области")
WIN_FIXED = 600.0     # м: окно за гребнем для хребта без нити (нет x_r), вдоль ветра
BAND = 200.0          # м: полуширина полосы поперёк ветра вокруг оси хребта
MENKE_NEAR = 250.0    # м: окно хребта пересекает разрез Menke -> Menke наблюдал ротор (Perdigão)


class RotorRun(C.Run):
    """C.Run + вариант rotor_jh (velocity_rotor с нитью, посчитанной rotor_vortex)."""

    def query(self, x, y, z, variant):
        if variant == "rotor_jh":
            return rotor3d.velocity_rotor(self.panels, self.sigma_rot, self.bg, self.fil, x, y, z, self.z0, infl=self.infl)
        return super().query(x, y, z, variant)


def git_short():
    try:
        return subprocess.check_output(["git", "rev-parse", "--short", "HEAD"], cwd=HERE, text=True).strip()
    except Exception:
        return "unknown"


def picard_u_par(case, level="picard_nom"):
    """Функция (x, y) -> u∥ Пикара на 15 м (линейно между 10 и 20 м; по x, y — ближайшая клетка), м/с."""
    with h5py.File(C.REFS / f"{case}.h5", "r") as h:
        wt = np.array(h.attrs["wind_to"], float)
        g = h[level]
        x, y, za = g["x"][:], g["y"][:], g["z_agl"][:]
        i10, i20 = int(np.argmin(abs(za - 10))), int(np.argmin(abs(za - 20)))
        sc = float(g["u"].attrs["scale"])
        u = 0.5 * (g["u"][i10].astype(float) + g["u"][i20].astype(float)) * sc      # [y, x]? проверяется ниже
        v = 0.5 * (g["v"][i10].astype(float) + g["v"][i20].astype(float)) * sc
        shape = g["u"].shape
    upar = u * wt[0] + v * wt[1]
    return x, y, upar


def lookup_picard(px, py, upar, X, Y):
    """Ближайшая клетка; массив upar индексируется [iy, ix] (как z в h5, ось 0 = y) — проверка по рельефу ниже."""
    ix = np.clip(np.rint((X - px[0]) / (px[1] - px[0])).astype(int), 0, len(px) - 1)
    iy = np.clip(np.rint((Y - py[0]) / (py[1] - py[0])).astype(int), 0, len(py) - 1)
    return upar[iy, ix]


def window_points(c, wt, x_c, y_c, length, step=15.0):
    """Точки окна за гребнем: от гребня вниз по ветру на length, полоса ±BAND поперёк."""
    ex, ey = wt
    nx_, ny_ = -ey, ex
    ss = np.arange(0.0, length + 1e-9, step)
    tt = np.arange(-BAND, BAND + 1e-9, 50.0)
    S, T = np.meshgrid(ss, tt)
    return x_c + S * ex + T * nx_, y_c + S * ey + T * ny_


def run_case(case, refs):
    t_all = time.time()
    run = RotorRun(case, refs=refs)
    nkey, Ud = RC.norm_info(case, refs)
    ex, ey = run.wt
    t0 = time.time()
    fil, sig, info = rotor3d.rotor_vortex(run.panels, run.bg, run.z0, run.infl, dict(PARAMS))
    t_rot = time.time() - t0
    run.fil, run.sigma_rot = fil, sig
    # масштаб u∥ к данным: U данных в опорной точке / |V_pan(norm)|
    x, y, z = run.points([nkey])
    u, v, _ = run.query(x, y, z, "rotor_jh")
    sn = float(math.hypot(u[0], v[0]))
    u_scale = Ud / sn
    trs = [t for t in refs["transects"] if t["case"] == case]
    rr = [r for r in refs["rotor"] if r["case"] == case]

    def ref_L(tr, src):
        m = [r for r in rr if r["transect"] == tr and r["source"] == src]
        return m[0]["L_m"] if m else None

    rows = []
    for tr in trs:
        present, L, depth = C.rotor_scan(run, "rotor_jh", tr, u_scale)
        # min u∥ на 15 м вдоль разреза / U опорной точки
        Lt = math.hypot(tr["x1"] - tr["x0"], tr["y1"] - tr["y0"])
        s = np.linspace(0, Lt, int(Lt // 10) + 1)
        X = tr["x0"] + (tr["x1"] - tr["x0"]) * s / Lt
        Y = tr["y0"] + (tr["y1"] - tr["y0"]) * s / Lt
        Z = run.panels.height(X, Y) + 15.0
        uu, vv, _ = run.query(X, Y, Z, "rotor_jh")
        up = (uu * ex + vv * ey) * u_scale
        up = up[np.isfinite(up)]
        rows.append(dict(case=case, transect=tr["name"], variant="rotor_jh", present=bool(present), L_m=float(L),
                         depth_m=float(depth), u_min_over_U=float(up.min() / Ud),
                         L_menke=ref_L(tr["name"], "menke2019"), L_picard_nom=ref_L(tr["name"], "picard_nom"),
                         L_picard_adv1=ref_L(tr["name"], "picard_adv1")))
    # --- хребты
    px, py, pup = picard_u_par(case)
    cands = info["candidates"]
    placed = {round(r["x_c"], 3): r for r in info["ridges"]}
    men_trs = [t for t in trs if t["name"].startswith("menke_")] if case != "ASK_TU03B" else []
    ridges = []
    for i, cd in enumerate(cands):
        r = placed.get(round(cd["x_c"], 3))
        x_c, y_c = cd["x_c"], cd["y_c"]
        if r is not None:
            length = max(WIN_FIXED * 0.0, 1.5 * float(np.hypot(r["x_r"] - r["x_c"], r["y_r"] - r["y_c"])))
        else:
            length = WIN_FIXED
        X, Y = window_points(run, run.wt, x_c, y_c, length)
        inb = (X > run.terrain.x.min() + 100) & (X < run.terrain.x.max() - 100) & (Y > run.terrain.y.min() + 100) & (Y < run.terrain.y.max() - 100)
        X, Y = X[inb], Y[inb]
        if len(X):
            Z = run.panels.height(X, Y) + 15.0
            uu, vv, _ = run.query(X, Y, Z, "rotor_jh")
            up = (uu * ex + vv * ey) * u_scale
            rev = bool((up < -0.5).any()) if r is not None else False      # нет нити — нет обратного тока от нити
            rev_field = bool((up < -0.5).any())
            pr = bool((lookup_picard(px, py, pup, X, Y) < -0.5).any())
        else:
            rev = rev_field = False
            pr = None
        menke = False
        for t in men_trs:       # окно пересекает разрез Menke (ротор наблюдён)
            a = np.array([t["x0"], t["y0"]]); b = np.array([t["x1"], t["y1"]])
            d = b - a
            p = np.stack([X, Y], -1) - a
            tt = np.clip((p @ d) / (d @ d), 0, 1)
            dist = np.linalg.norm(p - tt[..., None] * d, axis=-1)
            if len(dist) and dist.min() < MENKE_NEAR:
                menke = True
        ridges.append(dict(case=case, ridge=i, slope_max=None if cd["slope_lee"] is None else float(cd["slope_lee"]),
                           gate_pass=bool(cd["slope"]), placed=bool(r is not None and r["placed"]),
                           converged=bool(r is not None and r["converged"]),
                           Gamma=None if r is None else float(r["Gamma"]), R=None if r is None else float(r["R"]),
                           x_c=float(x_c * ex + y_c * ey),
                           x_r=None if r is None else float(r["x_r"] * ex + r["y_r"] * ey),
                           reverse_15m=rev, picard_reverse=pr, menke_rotor_nearby=menke,
                           false_rotor=bool(rev and pr is False and not menke),
                           window_m=float(length), reverse_field_15m=rev_field,
                           margin_to_gate=None if cd["slope_lee"] is None else float(cd["slope_lee"] - PARAMS["slope_min"]),
                           x_y_c=[float(x_c), float(y_c)]))
    timing = dict(case=case, t_s=float(run.t_mesh + run.info["t_assemble_s"] + run.info["t_solve_s"] + t_rot),
                  n_solves=int(info["nsolve"]) + 1, t_mesh_s=float(run.t_mesh), t_rotor_vortex_s=float(t_rot),
                  N=int(run.N), t_wall_s=float(time.time() - t_all))
    run.free()
    return rows, ridges, timing, info


def clean(o):
    """nan/inf -> None (JSON), numpy -> python."""
    if isinstance(o, dict):
        return {k: clean(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [clean(v) for v in o]
    if isinstance(o, (np.floating, float)):
        return float(o) if math.isfinite(o) else None
    if isinstance(o, np.bool_):
        return bool(o)
    if isinstance(o, np.integer):
        return int(o)
    return o


def main(argv):
    OUT.mkdir(parents=True, exist_ok=True)
    refs = C.load_refs()
    cases = argv or list(C.CASES)
    rows, ridges, timing, extra = [], [], [], {}
    for c in cases:
        for attempt in range(40):       # GPU делят с другими: при нехватке памяти ждём
            try:
                r, g, t, info = run_case(c, refs)
                break
            except Exception as e:
                if "OutOfMemory" not in type(e).__name__:
                    raise
                print(c, "GPU занят, повтор", attempt, flush=True)
                e = None
                import gc
                gc.collect()
                try:
                    import cupy as cp
                    cp.get_default_memory_pool().free_all_blocks()
                except Exception:
                    pass
                time.sleep(60)
        rows += r; ridges += g; timing.append(t)
        extra[c] = dict(n_ridges=info["n_ridges"], n_rejected=info["n_rejected"], n_unconverged=info["n_unconverged"])
        print(c, "разрезов", len(r), "хребтов", len(g), "нитей", sum(x["placed"] for x in g), f"{t['t_wall_s']:.0f} с", flush=True)
    doc = dict(format="swg-rotor", version=1, git=git_short(), created=time.strftime("%Y-%m-%dT%H:%M:%S"), task="swg-2",
               params=dict(PARAMS, sigma_m=C.SMOOTH_MAIN, ds_min=C.DS_MAIN, z0="медиана растра", bg="log"),
               criterion=CRITERION, rows=rows, ridges=ridges, timing=timing, case_info=extra)
    doc = clean(doc)
    name = "rotor.json" if not argv else "rotor_" + "_".join(argv) + ".json"      # часть случаев — отдельный файл (merge_rotor.py)
    tmp = OUT / (name + ".tmp")
    json.dump(doc, open(tmp, "w"), ensure_ascii=False, indent=1, allow_nan=False)
    os.replace(tmp, OUT / name)


if __name__ == "__main__":
    main(sys.argv[1:])
