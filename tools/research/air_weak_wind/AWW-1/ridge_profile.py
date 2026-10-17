"""AWW-1, диагноз 2 (склон): профиль у земли на наветренном склоне гряды (как холм над стартом «Термики»:
H 220 м, L 600 м) — зависимость u10/u100 от клетки (dx 50 / dz 25 как окно игры против dx 25 / dz 12,5)
при одном замыкании. Эталон air.py (тот же решатель, что air_picard.glsl). Точки: подножие (−1000 м), середина
склона (−400 м — как старт «Термики», 180 м над морем при вершине 223), вершина, подветренный склон (+400 м).
Запуск (venv с CuPy): $VENV/bin/python ridge_profile.py > out/ridge_profile.json
"""
import json
import math
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "air3d"))
sys.path.insert(0, str(HERE))
import air as A  # noqa: E402
import synth as SY  # noqa: E402
from flat_profile import at_agl, sample_col  # noqa: E402


def run(name, dx, dz, Lx, H, L, u10, z0, heat, alpha, max_outer=3000):
    nz = int(math.ceil((H + 1500.0) / dz)) + 1
    nz += nz % 2
    nx = int(round(Lx / dx))
    nx += nx % 2
    ny = max(16, int(round(1600.0 / dx)))
    ny += ny % 2
    g = A.Grid(dx, nx, ny, dz, -dz, nz, -nx * dx / 2, -ny * dx / 2)  # (x0, y0) — угол области
    X, Y = SY.XY(g)
    hc = SY.ridge3d(X, Y, H, L, half_len=4000.0)
    prm = A.Params(z0=z0, alpha=alpha, sponge_axes="x")
    if heat > 0:
        case = A.Case(U10=u10, wdir=270.0, H=np.full((ny, nx), heat), z_i=1550.0 + H, gam=SY.cbl_gam(1550.0 + H, 0.004))
    else:
        case = A.Case(U10=u10, wdir=270.0, gam=SY.const_gam(0.003))
    S = SY.run(g, hc, case, prm, max_outer=max_outer)
    info = SY.info(S)
    j = ny // 2
    pts = []
    for xoff in (-1000.0, -400.0, 0.0, 400.0):
        i = int(np.argmin(np.abs(g.x - xoff)))
        z, U, th = sample_col(S, i, j)
        u10m, u30, u100 = (at_agl(z, U, a, z0) for a in (10.0, 30.0, 100.0))
        k = np.where(np.isfinite(U))[0]
        pts.append({"x": float(g.x[i]), "hc": float(hc[j, i]), "u10": u10m, "u30": u30, "u100": u100,
                    "r10_100": u10m / u100, "r10_30": u10m / u30,
                    "first_cells": [[float(z[q]), float(U[q])] for q in k[:4]]})
    out = {"name": name, "dx": dx, "dz": dz, "status": info["status"], "iters": info["iters"], "pts": pts}
    print(f"{name}: {info['status']} {info['iters']} " + " | ".join(
        f"x{p['x']:+.0f} r10_100 {p['r10_100']:.3f} r10_30 {p['r10_30']:.3f} u10 {p['u10']:.2f}" for p in pts), file=sys.stderr)
    return out


def main():
    res = []
    for heat, alpha, tag in ((0.0, 0.24, "neutral"), (300.0, 0.112, "conv")):
        for dx, dz in ((50.0, 25.0), (25.0, 12.5), (100.0, 50.0)):
            res.append(run(f"ridge_{tag}_dx{int(dx)}", dx, dz, 6400.0, 220.0, 600.0, 2.0, 0.03, heat, alpha))
    print(json.dumps(res, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
