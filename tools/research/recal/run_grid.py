"""Перекалибровка Askervein по (λ/h, α, z0): прогоны на сетке → out/runs.jsonl (по строке на точку,
продолжение с места). Решатель — air.py через обёртку Морриса (model.py; прочие факторы — номинал:
hb, adv2, local_k, Pr_t = 1). Кроме наблюдаемых AM-09 пишет S(RS, h) — профиль опорной мачты.

  python run_grid.py [grid.json]      (по умолчанию config.json → "grid")
"""
from __future__ import annotations

import json
import math
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "morris"))
import model as M                     # noqa: E402  (A.Air = MAir; при Pr_t = 1, hb — тот же air.py)
import askervein as AK                # noqa: E402
import askervein_runs as R            # noqa: E402

CFG = json.loads((HERE / "config.json").read_text())
OUT = HERE / "out"
RS_H = CFG["rs_heights"]


def grid_points(gcfg):
    lf = np.exp(np.linspace(math.log(gcfg["lam_frac"][0]), math.log(gcfg["lam_frac"][1]), gcfg["lam_frac"][2]))
    al = np.linspace(*gcfg["alpha"][:2], gcfg["alpha"][2])
    z0 = np.exp(np.linspace(math.log(gcfg["z0"][0]), math.log(gcfg["z0"][1]), gcfg["z0"][2]))
    return [(float(a), float(b), float(c)) for a in lf for b in al for c in z0]


def run_one(lf, al, z0, dx=25.0):
    fx = {f["name"]: f["nom"] for f in M.FACTORS}
    fx.update(lam_frac=lf, alpha_mul=al / 0.17, z0_mul=z0 / 0.03)
    L, top = 4000.0, 1000.0
    x0, y0, n, hc = AK.terrain(dx, L)
    dz = dx / 2
    nz = int(math.ceil(top / dz)) + 1
    nz += nz % 2
    g = M.A.Grid(dx, n, n, dz, -dz, nz, x0, y0)
    prm = M.params(fx, 0.03, 0.17, max_profile=2.0, f_cor=1.22e-4, sponge_side_m=1000.0)
    case = M.A.Case(U10=8.9, wdir=210.0, gam=M.SY.const_gam(0.0))
    S = M.SY.run(g, hc, case, prm, max_outer=4000)
    u, v, w, th = S.centers()
    sp = np.sqrt(u ** 2 + v ** 2 + w ** 2)
    obs = {k: float(x) for k, x in R.model_obs(S, g, sp).items()}
    rs = {f"{h:g}": float(R.bil(g, M.SY.agl(S, sp, float(h)), *AK.RS)) for h in RS_H}
    out = dict(lam_frac=lf, alpha=al, z0=z0, dx=dx, **M.meta(S), obs=obs, rs=rs)
    M.free(S)
    return out


def main():
    gname = sys.argv[1] if len(sys.argv) > 1 else "grid"
    pts = grid_points(CFG[gname])
    OUT.mkdir(exist_ok=True)
    f = OUT / f"runs_{gname}.jsonl"
    done = set()
    if f.exists():
        for line in f.read_text().splitlines():
            r = json.loads(line)
            done.add((round(r["lam_frac"], 6), round(r["alpha"], 6), round(r["z0"], 6)))
    dx = CFG[gname].get("dx", 25.0)
    t0 = time.perf_counter()
    for i, (lf, al, z0) in enumerate(pts):
        if (round(lf, 6), round(al, 6), round(z0, 6)) in done:
            continue
        with M.GpuLock():
            try:
                r = run_one(lf, al, z0, dx)
            except Exception as e:                       # noqa: BLE001
                r = dict(lam_frac=lf, alpha=al, z0=z0, dx=dx, status="error", err=repr(e))
        with open(f, "a") as fh:
            fh.write(json.dumps(r) + "\n")
        print(f"{i + 1}/{len(pts)} lf={lf:.3f} a={al:.3f} z0={z0:.3f} {r['status']} "
              f"{time.perf_counter() - t0:.0f}s", flush=True)


if __name__ == "__main__":
    main()
