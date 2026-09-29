#!/usr/bin/env python3
"""Опыт 4: установившееся поле проходами по слоям (матрицы перехода) — прогоны, замеры, картинки.

  ../.venv/bin/python run4.py refs_long          # автомат до 12 ч модельного времени → out/refs_long (сверка «точной» неподвижной точки)
  ../.venv/bin/python run4.py accuracy           # 4 сценария × 200/100/50/25 м: сходимость повторов, ошибки, числа → out/results/*.json, out/fields/*.npz
  flock /tmp/heat_ca_gpu.lock ../.venv/bin/python run4.py timing   # время на GPU (под замком) → out/timing.json
  ../.venv/bin/python run4.py warm               # тёплый старт (соседний час / инверсия) → out/warm.json
  ../.venv/bin/python run4.py figs               # картинки → out/*.png
  ../.venv/bin/python run4.py tables             # таблицы → out/tables.md
Ключи: --scen s1_sun_one_slope,s3_wind  --cells 200,50  --mem 64  --iters 600
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from model import SCENARIOS, Params, HeatCA  # noqa: E402
import plots  # noqa: E402

BASE = os.path.dirname(HERE)
REFS = os.path.join(BASE, "out", "refs")
OUT = os.path.join(HERE, "out")
NAMES = ["s1_sun_one_slope", "s2_both_slopes", "s3_wind", "s4_inversion"]
CELLS = [200.0, 100.0, 50.0, 25.0]
TOL = 0.02          # «сошлось»: w, u, θ′ отличаются от окончательного решения < 2 % (L2)
SNAP = 5            # снимок состояния раз в столько повторов


def ref_path(name, cell):
    """Эталон базы (out/refs); клеток, которых там нет (12,5 м), — свой (out/refs_extra, тот же формат)."""
    p = os.path.join(REFS, f"{name}_{cell:g}.npz")
    return p if os.path.exists(p) else os.path.join(OUT, "refs_extra", f"{name}_{cell:g}.npz")


def load_ref(name, cell, long=False):
    p = os.path.join(OUT, "refs_long", f"{name}_{cell:g}.npz") if long else ref_path(name, cell)
    if not os.path.exists(p):
        return None
    d = np.load(p)
    return {k: d[k] for k in d.files}


def rel(a, b, air):
    return float(np.sqrt(np.nansum((a - b)[air] ** 2) / np.nansum(b[air] ** 2)))


def errs(f, r, air):
    return dict(w=rel(f[1], r["wc"], air), u=rel(f[0], r["uc"], air), th=rel(f[2], r["th"], air))


# ------------------------------------------------------------------ длинный эталон
def cmd_refs_long(args):
    from model import run as run_ca
    os.makedirs(os.path.join(OUT, "refs_long"), exist_ok=True)
    for name in args.scen:
        for cell in args.cells:
            p = os.path.join(OUT, "refs_long", f"{name}_{cell:g}.npz")
            if os.path.exists(p):
                continue
            pr = Params(cell=cell, t_max=12 * 3600.0, steady_dv=-1.0, steady_dT=-1.0)
            m, _, series, info = run_ca(SCENARIOS[name], pr, record=False, verbose=False)
            uc, wc, th = m.centers()
            np.savez_compressed(p, uc=uc, wc=wc, th=th, info=json.dumps(dict(t_model=m.t, steps=m.steps)))
            print(f"{name} {cell:g} м: 12 ч модельного времени, {m.steps} шагов", flush=True)


def cmd_refs_extra(args):
    """Эталон для клеток, которых нет в базе (12,5 м): тот же refs.py базы — run() с досрочной остановкой.
    Время до установления пишется в info — запускать под замком GPU."""
    from model import run as run_ca
    os.makedirs(os.path.join(OUT, "refs_extra"), exist_ok=True)
    for name in args.scen:
        for cell in args.cells:
            model, _, series, info = run_ca(SCENARIOS[name], Params(cell=cell, t_max=6 * 3600.0), record=False,
                                             verbose=False)
            uc, wc, th = model.centers()
            meta = dict(scenario=name, cell=cell, nx=model.nx, nz=model.nz, dt=info["dt"],
                        steady_step=info["steady_step"], steady_t=info["steady_t"], steady_wall=info["steady_wall"],
                        ms_step=info["wall"] / info["steps"] * 1e3, params=info["params"],
                        m_res=series[-1]["m_res"], h_res=series[-1]["h_res"])
            np.savez_compressed(os.path.join(OUT, "refs_extra", f"{name}_{cell:g}.npz"), uc=uc, wc=wc, th=th,
                                solid=model.solid_np, xc=model.xc, zc=model.zc, h=model.h, kb=model.kb,
                                q=model.q_np, info=json.dumps(meta, default=float))
            print(f"{name} {cell:g} м: эталон {info['steady_step']} шагов, {info['steady_wall']:.2f} с", flush=True)


# ------------------------------------------------------------------ точность и сходимость
def make(name, cell, mem):
    import cupy as cp
    from steady4 import SteadyOp
    from gpu import GpuSteady
    op = SteadyOp(SCENARIOS[name], Params(cell=cell), xp=cp, dtype=np.float32)
    g = GpuSteady(op, mem=mem)
    return op, g


def cmd_accuracy(args):
    os.makedirs(os.path.join(OUT, "results"), exist_ok=True)
    os.makedirs(os.path.join(OUT, "fields"), exist_ok=True)
    for name in args.scen:
        for cell in args.cells:
            op, g = make(name, cell, args.mem)
            g.capture()
            ref = load_ref(name, cell)
            refL = load_ref(name, cell, long=True)
            air = ~ref["solid"]
            snaps, res = [], []
            while g.n < args.iters:
                for _ in range(SNAP if g.n > 0 else 1):
                    g.step()
                g.stream.synchronize()
                rr = g.residual_rms()
                if not np.isfinite(rr):
                    print(f"  ! {name} {cell:g} м: нечисло на повторе {g.n} — берём последний снимок", flush=True)
                    break
                snaps.append((g.n, op.centers(g.x)))
                res.append((g.n, rr))
                if rr < args.stop:       # дошли до пола точности float32: дальше история Андерсона вырождается
                    break
            fin = snaps[-1][1]
            finr = dict(uc=fin[0], wc=fin[1], th=fin[2])
            hist = []
            for (n, f), (_, r) in zip(snaps, res):
                h = dict(n=n, res=r, fin=errs(f, finr, air), ref=errs(f, ref, air))
                if refL is not None:
                    h["refL"] = errs(f, refL, air)
                hist.append(h)

            def first_stay(tol):
                ok = [max(h["fin"].values()) < tol for h in hist]
                for i in range(len(ok)):
                    if all(ok[i:]):
                        return hist[i]["n"]
                return None
            n2, n5, n1 = first_stay(0.02), first_stay(0.05), first_stay(0.01)
            # поле на момент «сошлось (2 %)» — оно и идёт в таблицы/картинки
            i2 = [h["n"] for h in hist].index(n2) if n2 is not None else len(hist) - 1
            f2 = snaps[i2][1]
            m = op.m
            met = plots.metrics(m, *f2)
            met_ref = plots.metrics(m, ref["uc"], ref["wc"], ref["th"])
            met_L = plots.metrics(m, refL["uc"], refL["wc"], refL["th"]) if refL is not None else None
            info = json.loads(str(ref["info"]))
            out = dict(scenario=name, cell=cell, mem=args.mem, iters=args.iters, n_conv2=n2, n_conv5=n5, n_conv1=n1,
                       final_res=res[-1][1], err_ref=errs(f2, ref, air), err_fin_ref=errs(fin, ref, air),
                       err_refL=errs(f2, refL, air) if refL is not None else None,
                       err_ref_vs_refL=errs((ref["uc"], ref["wc"], ref["th"]), refL, air) if refL is not None else None,
                       metrics=met, metrics_ref=met_ref, metrics_refL=met_L, ref_info=info, hist=hist,
                       nx=op.nx, nz=op.nz, M=op.M, basis=op.basis, cells_air=int(air.sum()))
            with open(os.path.join(OUT, "results", f"{name}_{cell:g}.json"), "w") as fh:
                json.dump(out, fh, indent=1, default=float)
            nsave = [i for i, (n, _) in enumerate(snaps) if n <= (n2 or args.iters) + 20]
            np.savez_compressed(os.path.join(OUT, "fields", f"{name}_{cell:g}.npz"), uc=f2[0], wc=f2[1], th=f2[2],
                                uc_fin=fin[0], wc_fin=fin[1], th_fin=fin[2], n_conv2=n2 or -1)
            os.makedirs(os.path.join(OUT, "snaps"), exist_ok=True)    # снимки по повторам (для анимации)
            np.savez_compressed(os.path.join(OUT, "snaps", f"{name}_{cell:g}.npz"),
                                snap_n=np.array([snaps[i][0] for i in nsave]),
                                snap_uc=np.array([snaps[i][1][0] for i in nsave], np.float32),
                                snap_wc=np.array([snaps[i][1][1] for i in nsave], np.float32),
                                snap_th=np.array([snaps[i][1][2] for i in nsave], np.float32))
            e = out["err_ref"]
            print(f"{name} {cell:g} м: сошлось (2 %) за {n2} повторов (5 %: {n5}, 1 %: {n1}); ошибка против эталона "
                  f"w {e['w']:.3f} u {e['u']:.3f} θ′ {e['th']:.3f}; невязка {res[-1][1]:.1e}", flush=True)
            del g, op
            import cupy as cp
            cp.get_default_memory_pool().free_all_blocks()


# ------------------------------------------------------------------ время
def gpu_name():
    import cupy as cp
    return cp.cuda.runtime.getDeviceProperties(0)["name"].decode()


def cmd_timing(args):
    import cupy as cp
    rows = []
    for name in args.scen:
        for cell in args.cells:
            r = json.load(open(os.path.join(OUT, "results", f"{name}_{cell:g}.json")))
            n2 = r["n_conv2"] or r["iters"]
            best = None
            for rep in range(3):
                op, g = make(name, cell, args.mem)
                g.capture()
                cp.cuda.Device().synchronize()
                t, n, _ = g.run(n2, check_every=n2)
                # отдельно: чистая стоимость одного повтора (много повторов подряд)
                best = t if best is None else min(best, t)
                del g, op
                cp.get_default_memory_pool().free_all_blocks()
            op, g = make(name, cell, args.mem)
            g.capture()
            t_many, n_many, _ = g.run(200, check_every=200)
            ms_iter = t_many / n_many * 1e3
            parts = g.time_parts()
            ms_pass = parts["two_pass"]
            info = r["ref_info"]
            row = dict(scenario=name, cell=cell, nx=op.nx, nz=op.nz, M=op.M, n_conv2=n2, t_gpu=best,
                       ms_iter=ms_iter, ms_two_pass_kernel=ms_pass, ms_residual=parts["residual"],
                       ms_sweeps=parts["sweeps"], ref_steps=info["steady_step"],
                       ref_wall=info["steady_wall"], ref_ms_step=info["ms_step"], N=g.N, mem=args.mem,
                       mem_mb=(cp.get_default_memory_pool().total_bytes() + g._pool.total_bytes()) / 2**20)
            rows.append(row)
            print(f"{name} {cell:g} м: {n2} повторов, {best:.3f} с GPU ({ms_iter:.3f} мс/повтор, ядро двух проходов "
                  f"{ms_pass*1e3:.1f} мкс); эталон {info['steady_step']} шагов / {info['steady_wall']:.2f} с", flush=True)
            del g, op
            cp.get_default_memory_pool().free_all_blocks()
    tp = os.path.join(OUT, "timing.json")
    keep = []
    if os.path.exists(tp):      # дописываем к прошлым замерам (другие клетки/сценарии)
        new = {(r["scenario"], r["cell"]) for r in rows}
        keep = [r for r in json.load(open(tp))["rows"] if (r["scenario"], r["cell"]) not in new]
    allr = sorted(keep + rows, key=lambda r: (NAMES.index(r["scenario"]), -r["cell"]))
    with open(tp, "w") as fh:
        json.dump(dict(gpu=gpu_name(), rows=allr), fh, indent=1, default=float)


# ------------------------------------------------------------------ тёплый старт
def cmd_warm(args):
    """Старт не с покоя, а с соседнего решения: как в игре при смене часа/погоды."""
    import cupy as cp
    from steady4 import SteadyOp
    from gpu import GpuSteady
    cases = [
        ("солнце 20° → 25° (сценарий 1, час раньше)", dataclasses.replace(SCENARIOS["s1_sun_one_slope"], sun_elev_deg=20.0),
         SCENARIOS["s1_sun_one_slope"]),
        ("нагрев 200 → 250 Вт/м² (сценарий 2)", dataclasses.replace(SCENARIOS["s2_both_slopes"], q0_wm2=200.0),
         SCENARIOS["s2_both_slopes"]),
        ("без инверсии → инверсия (сценарий 2 → 4)", SCENARIOS["s2_both_slopes"], SCENARIOS["s4_inversion"]),
        ("ветер 2,5 → 3 м/с (сценарий 3)", dataclasses.replace(SCENARIOS["s3_wind"], wind_ms=2.5), SCENARIOS["s3_wind"]),
    ]
    rows = []
    for cell in args.cells:
        for title, sc0, sc1 in cases:
            op0 = SteadyOp(sc0, Params(cell=cell), xp=cp, dtype=np.float32)
            g0 = GpuSteady(op0, mem=args.mem)
            g0.capture()
            g0.run(args.iters, check_every=args.iters)
            x0 = g0.x.copy()
            op1 = SteadyOp(sc1, Params(cell=cell), xp=cp, dtype=np.float32)
            air = ~op1.m.solid_np
            res = {}
            for start in ("cold", "warm"):
                g = GpuSteady(op1, mem=args.mem)
                if start == "warm":
                    g.x[...] = x0
                    cp.cuda.Device().synchronize()
                g.capture()
                snaps = []
                while g.n < args.iters:
                    for _ in range(SNAP if g.n > 0 else 1):
                        g.step()
                    g.stream.synchronize()
                    snaps.append((g.n, op1.centers(g.x)))
                res[start] = snaps
            fin = res["cold"][-1][1]
            finr = dict(uc=fin[0], wc=fin[1], th=fin[2])
            row = dict(case=title, cell=cell)
            for start, snaps in res.items():
                ok = [max(errs(f, finr, air).values()) < TOL for _, f in snaps]
                n2 = next((snaps[i][0] for i in range(len(ok)) if all(ok[i:])), None)
                row[start] = n2
                row[start + "_err0"] = errs(snaps[0][1], finr, air)
            rows.append(row)
            print(row, flush=True)
            del g0, op0, g, op1
            cp.get_default_memory_pool().free_all_blocks()
    with open(os.path.join(OUT, "warm.json"), "w") as fh:
        json.dump(rows, fh, indent=1, default=float)


# ------------------------------------------------------------------ картинки и таблицы
def cmd_figs(args):
    import figs4
    figs4.all_figs(OUT, NAMES, CELLS + [12.5])


def cmd_tables(args):
    import figs4
    figs4.tables(OUT, NAMES, CELLS + [12.5])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd")
    ap.add_argument("--scen", default=",".join(NAMES))
    ap.add_argument("--cells", default=",".join(f"{c:g}" for c in CELLS))
    ap.add_argument("--mem", type=int, default=64)
    ap.add_argument("--iters", type=int, default=600)
    ap.add_argument("--stop", type=float, default=3e-7, help="остановка по ‖f‖_rms (пол float32)")
    a = ap.parse_args()
    a.scen = a.scen.split(",")
    a.cells = [float(c) for c in a.cells.split(",")]
    dict(refs_long=cmd_refs_long, refs_extra=cmd_refs_extra, accuracy=cmd_accuracy, timing=cmd_timing, warm=cmd_warm, figs=cmd_figs,
         tables=cmd_tables)[a.cmd](a)


if __name__ == "__main__":
    main()
