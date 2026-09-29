#!/usr/bin/env python3
"""3D-Пикар на рельефе Онгудая: время, сходимость, тёплый старт, интерполяция по часам, размер.

  ../heat_ca/.venv/bin/python study.py conv    [--dx 400,200]  → out/conv.json          (ошибка против итераций)
  ../heat_ca/.venv/bin/python study.py matrix  [--dx 400,200]  → out/matrix.json        (часы × ветер × нагрев)
  ../heat_ca/.venv/bin/python study.py warm    [--dx 200]      → out/warm.json          (тёплый старт)
  ../heat_ca/.venv/bin/python study.py cells                   → out/cells.json         (400/200/100/50 м)
  ../heat_ca/.venv/bin/python study.py size                    → out/size.json          (размер полей)
Замеры времени — под общим замком GPU: flock /tmp/heat_ca_gpu.lock ...
Поля — fields/*.npz (fp16, вне git), маленькие — out/fields/*.npz.
"""
from __future__ import annotations

import argparse
import itertools
import json
import math
import sys
import time

import numpy as np

import common as C
import solver as S

OUT = C.OUT


def rel(a, b):
    m = ~(np.isnan(a) | np.isnan(b))
    return float(np.sqrt(np.sum((a - b)[m] ** 2) / max(np.sum(b[m] ** 2), 1e-30)))


def maxabs(a, b):
    m = ~(np.isnan(a) | np.isnan(b))
    return float(np.max(np.abs(a - b)[m]))


def field_err(F, R):
    names = ("u", "v", "w", "th")
    return {n: dict(rel=rel(f, r), max=maxabs(f, r)) for n, f, r in zip(names, F, R)}


def gpu_info():
    import cupy as cp
    p = cp.cuda.runtime.getDeviceProperties(0)
    return dict(name=p["name"].decode(), mem_gb=p["totalGlobalMem"] / 2 ** 30)


# ---------------------------------------------------------------------------- conv
def cmd_conv(args):
    """Досчитать далеко (эталон X*), по ходу — снимки; ошибка против итераций и невязки."""
    res = dict(gpu=gpu_info(), cases=[])
    cases = [("calm_h13", S.Cond(hour=13, wind=0)),
             ("U3w_h13", S.Cond(hour=13, wind=3, wdir=270)),
             ("U6w_h13", S.Cond(hour=13, wind=6, wdir=270)),
             ("U3w_noheat", S.Cond(hour=None, wind=3, wdir=270))]
    for dx in args.dx:
        for name, cond in cases:
            g = C.grid_domain(dx)
            A = C.make(g, cond)
            snaps = []
            every = 10 if dx >= 400 else 20

            def cb(A_, r):
                if A_.outer % every == 1 or A_.outer <= 11:
                    snaps.append((A_.outer, r["t"], A_.centers()))
            A.init_background()
            A.solve(tol_mom=0, max_outer=args.max_outer, check_every=10, cb=cb)
            X = A.centers()
            hist = A.hist
            errs = [dict(it=it, t=t, **{k: v for k, v in field_err(F, X).items()}) for it, t, F in snaps]
            # первая итерация, после которой ошибка w (отн. L2) < 1 % и < 0,1 %
            def first(th):
                for e in errs:
                    if e["w"]["rel"] < th and e["u"]["rel"] < th:
                        return e["it"]
                return None
            # итерация, где сработал бы критерий TOL
            tol_it = None
            for r in hist:
                if r["mom_rms"] < C.TOL["tol_mom"] and r["th_rms"] < C.TOL["tol_th"] and r["div_rms"] < C.TOL["tol_div"]:
                    tol_it = r["it"]
                    break
            e_tol = next((e for e in errs if tol_it is not None and e["it"] >= tol_it), None)
            case = dict(dx=dx, name=name, cond=cond.__dict__, prm=dict(C.PRM), iters=A.outer, wall=A.wall - A.t_check,
                        it_per_s=A.outer / max(A.wall - A.t_check, 1e-9), hist=hist, errs=errs,
                        it_1pc=first(0.01), it_01pc=first(0.001), tol_it=tol_it, err_at_tol=e_tol,
                        budget=A.heat_budget(), keys=C.key_numbers(A, X), mem_mb=A.mem_mb())
            print(f"{dx:.0f} м {name}: {A.outer} итер. {case['wall']:.2f} с; 1 % на {case['it_1pc']}, 0,1 % на "
                  f"{case['it_01pc']}, критерий на {tol_it} (ошибка w {e_tol['w']['rel'] if e_tol else None})",
                  flush=True)
            res["cases"].append(case)
            del A, snaps
            import cupy as cp
            cp.get_default_memory_pool().free_all_blocks()
    C.jdump(res, OUT / f"conv{args.tag}.json")


# ---------------------------------------------------------------------------- matrix
HOURS = [9, 11, 12, 13, 15, 17]
DIRS8 = [0, 45, 90, 135, 180, 225, 270, 315]
DIRS4 = [0, 90, 180, 270]


def winds():
    return [(0.0, 0.0)] + [(3.0, d) for d in DIRS8] + [(6.0, d) for d in DIRS4]


def light(r):
    """Итог прогона без длинной истории."""
    out = {k: v for k, v in r.items() if k != "hist"}
    out["hist"] = [{k: h[k] for k in ("it", "mom_rms", "mom_max", "th_rms", "div_rms", "t")} for h in r["hist"]]
    return out


def cmd_matrix(args):
    res = dict(gpu=gpu_info(), tol=C.TOL, prm=C.PRM, runs=[])
    for dx in args.dx:
        g = C.grid_domain(dx)
        fdir = C.FIELDS / f"d{int(dx)}"
        fdir.mkdir(exist_ok=True)
        for (U, d) in winds():
            for hour in HOURS + [None]:
                cond = S.Cond(hour=hour, wind=U, wdir=d if U > 0 else 270.0)
                t0 = time.perf_counter()
                A = C.make(g, cond)
                t_setup = time.perf_counter() - t0
                r = C.run(A)
                X = A.centers()
                rec = dict(dx=dx, key=cond.key(), hour=hour, wind=U, wdir=d, t_setup=t_setup,
                           budget=A.heat_budget(), keys=C.key_numbers(A, X), sun=A.sun,
                           cells=int(np.prod(A.shape)), fluid=int(A.n_fluid), **light(r))
                C.save_fields(A, fdir / f"{cond.key()}.npz")
                print(f"{dx:.0f} м {cond.key():18s} {r['status']:8s} {r['iters']:4d} итер. {r['t_solve']:.2f} с "
                      f"(+проверки {r['t_check']:.2f}, подготовка {t_setup:.1f}+{r['t_init']:.2f}) "
                      f"w200 p99 {rec['keys']['w200_p99']:.2f}  баланс {rec['budget']['rel']:.1e}", flush=True)
                res["runs"].append(rec)
                del A
                import cupy as cp
                cp.get_default_memory_pool().free_all_blocks()
        C.jdump(res, OUT / f"matrix{args.tag}.json")


# ---------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd")
    ap.add_argument("--dx", default="400")
    ap.add_argument("--max-outer", type=int, default=600)
    ap.add_argument("--tag", default="")
    ap.add_argument("--prm", default="", help="переопределить параметры решателя: dict(...)")
    args = ap.parse_args()
    if args.prm:
        C.PRM.update(eval(args.prm))
    args.dx = [float(x) for x in args.dx.split(",")]
    globals()["cmd_" + args.cmd](args)


if __name__ == "__main__":
    main()
