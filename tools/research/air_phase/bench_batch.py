"""AP-1: замер пакетного решателя (bench.json) и идеальные формы по формулам P1 (docs/contracts/air-phase.md) — только для тестов и замеров AP-1
(канонический генератор — reliefs.ideal_relief, AP-2). g100 (384, 384), м н. у. м., узлы — центры клеток."""
from __future__ import annotations

import math
import sys

import numpy as np

N100, DX100, X0 = 384, 100.0, -19200.0


def ideal_g100(shape, s, h=500.0, length=20000.0, base=1000.0):
    x = X0 + 50.0 + DX100 * np.arange(N100)
    X, Y = np.meshgrid(x, x)              # [j север, i восток]
    if shape in ("hill", "ridge"):
        a = h * math.sqrt(2.0) * math.exp(-0.5) / s
        if shape == "hill":
            z = h * np.exp(-(X ** 2 + Y ** 2) / a ** 2)
        else:
            T = np.exp(-np.maximum(0.0, np.abs(Y) - (length / 2 - a)) ** 2 / a ** 2)
            z = h * np.exp(-X ** 2 / a ** 2) * T
    elif shape in ("step_up", "step_down"):
        a = h / (2.0 * s)
        z = h * (1 + np.tanh(X / a)) / 2 if shape == "step_up" else h * (1 - np.tanh(X / a)) / 2
    else:
        raise ValueError(shape)
    return base + z


# ============================================================================== замер пакета (P4: bench.json)
CTX = dict(lat=50.79, lon=86.13, month=7, day=15, hour_local=12.0, utc_offset=7.0, t_max_c=26.0, sky="clear")
ALPHA, MAXP, N_BV, H_FORM = 0.24, 2.341, 0.01, 500.0
FORCE_IT = 200                       # итераций на случай в замере пропускной способности (сходимость отключена)


def spec_fr(BS, shape, s, fr, h_over_zi=0.3, heat=0.0, dx=400.0):
    return BS.CaseSpec(g100=ideal_g100(shape, s), ctx=CTX, u10=fr * N_BV * H_FORM / MAXP, wdir_from_deg=270.0, alpha=ALPHA,
                       max_profile=MAXP, n_bv_s=N_BV, z_i_agl_m=H_FORM / h_over_zi, heat_flux_wm2=heat, dx_m=dx)


def mix(BS, n):
    """n случаев вперемешку: формы × Fr × нагрев (как GRID)."""
    shapes = ("hill", "ridge", "step_up")
    frs = (0.3, 0.6, 1.0, 2.0, 3.0)
    return [spec_fr(BS, shapes[k % 3], (0.15, 0.3, 0.5)[(k // 3) % 3], frs[k % 5], heat=(0.0, 100.0)[k % 2]) for k in range(n)]


def run_throughput(B, n):
    import batch_solver as BS
    specs = mix(BS, n)
    num = BS.Numerics(max_outer=FORCE_IT, late_from=FORCE_IT, criterion="abs", tol=1e-30)
    BS.solve_batch(specs[:1], BS.Numerics(max_outer=20, late_from=20))        # прогрев (компиляция ядер)
    res = BS.solve_batch(specs, num, batch=B)
    st = dict(BS.LAST_STATS)
    its = sum(r.iters for r in res)
    s_per_it = st["wall"] / its
    return dict(B=B, n_cases=n, iters_total=its, wall_s=round(st["wall"], 2), ms_per_case_iter=round(1000 * s_per_it, 3),
                cases_per_h_1000it=round(3600 / (s_per_it * 1000), 1), peak_mem_mb=round(st["peak_mem_mb"]))


def run_types():
    """Время одного случая (B = 1, Numerics по умолчанию, max_outer 1000) по типам."""
    import batch_solver as BS
    cases = {"strong_fr3_hill_s0.3": (spec_fr(BS, "hill", 0.3, 3.0), BS.Numerics()),
             "weak_fr0.2_ridge_s0.3": (spec_fr(BS, "ridge", 0.3, 0.2), BS.Numerics()),
             "mid_fr0.6_ridge_s0.3_H100": (spec_fr(BS, "ridge", 0.3, 0.6, heat=100.0), BS.Numerics()),
             "window100_fr3_stepdown_s0.3": (spec_fr(BS, "step_down", 0.3, 3.0, dx=100.0), BS.Numerics()),
             "envelope12_ground_fr3_stepdown_s0.3": (spec_fr(BS, "step_down", 0.3, 3.0),
                                                     BS.Numerics(envelope_angle_deg=12.0, envelope_wall="ground"))}
    out = {}
    for k, (sp, nm) in cases.items():
        r = BS.solve_batch([sp], nm, batch=1)[0]
        d = dict(status=r.status, iters=r.iters, seconds=round(r.wall_own, 2))
        if r.window is not None:
            d.update(window_status=r.window["status"], window_iters=r.window["iters"],
                     window_cells=[r.window["meta"]["nx"], r.window["meta"]["ny"], r.window["meta"]["nz"]],
                     downwind_fit_over_h=round(r.window["meta"]["downwind_fit_over_h"], 2))
        out[k] = d
        print(k, d, flush=True)
    return out


def main(argv=None):
    import argparse
    import json
    import os
    import subprocess
    from pathlib import Path
    ap = argparse.ArgumentParser(description="Замер пакетного решателя AP-1 → out/bench.json (под dp lock gpu)")
    ap.add_argument("--worker", type=int, default=0, help="служебное: один процесс из N (B = 1, n случаев)")
    ap.add_argument("--n", type=int, default=4)
    ap.add_argument("--batches", default="1,2,4,8,16,32")
    ap.add_argument("--out", default=str(Path(__file__).resolve().parent / "out" / "bench.json"))
    a = ap.parse_args(argv)
    if a.worker:
        print("RESULT", json.dumps(run_throughput(1, a.n)), flush=True)
        return
    import batch_solver as BS
    import cupy as cp
    rows = []
    for B in [int(b) for b in a.batches.split(",")]:
        r = run_throughput(B, max(2 * B, 8))
        rows.append(r)
        print(r, flush=True)
    procs = []
    for n in (1, 2, 4):     # N процессов, каждый B = 1 (как воркеры SY-8/SY-10)
        ps = [subprocess.Popen([sys.executable, __file__, "--worker", "1", "--n", "4"], stdout=subprocess.PIPE, text=True)
              for _ in range(n)]
        import time as _t
        t0 = _t.perf_counter()
        outs = [p.communicate()[0] for p in ps]
        wall = _t.perf_counter() - t0
        its = sum(json.loads(l.split("RESULT ", 1)[1])["iters_total"] for o in outs for l in o.splitlines() if l.startswith("RESULT"))
        s_per_it = wall / its        # включая запуск процессов и компиляцию — верхняя оценка
        inner = [json.loads(l.split("RESULT ", 1)[1])["ms_per_case_iter"] for o in outs for l in o.splitlines() if l.startswith("RESULT")]
        procs.append(dict(processes=n, ms_per_case_iter_inner_mean=round(float(np.mean(inner)), 3),
                          cases_per_h_1000it_inner=round(n * 3600 / (float(np.mean(inner)) / 1000 * 1000), 1),
                          cases_per_h_1000it_wall=round(3600 / (s_per_it * 1000), 1)))
        print(procs[-1], flush=True)
    types = run_types()
    best = max(rows, key=lambda r: r["cases_per_h_1000it"])
    one = next(r for r in rows if r["B"] == 1)
    out = dict(device=cp.cuda.runtime.getDeviceProperties(0)["name"].decode(), solver_version=BS.solver_version(),
               method="пакет = B решателей в одном процессе, свой поток CUDA и граф у каждого; пропускная способность — при "
                      f"{FORCE_IT} итерациях на случай без проверки сходимости (tol 1e-30), пересчёт на 1000 итераций",
               by_batch=rows, by_processes=procs, best_batch=best["B"],
               speedup_vs_1=round(best["cases_per_h_1000it"] / one["cases_per_h_1000it"], 2), b_default=BS.B_DEFAULT,
               case_types_B1=types)
    Path(a.out).parent.mkdir(exist_ok=True)
    Path(a.out).write_text(json.dumps(out, indent=1, ensure_ascii=False))
    print(json.dumps({k: out[k] for k in ("best_batch", "speedup_vs_1")}))


if __name__ == "__main__":
    import sys
    sys.path.insert(0, str(__import__("pathlib").Path(__file__).resolve().parent))
    main()
