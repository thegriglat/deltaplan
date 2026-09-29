#!/usr/bin/env python3
"""Опыт 5 — прогоны и замеры: раунды прогонок (ADI) до установившегося поля автомата.

  ../.venv/bin/python exp5.py sweep  [сценарий клетка ...]   # подбор, стадия 1 (Δτ общий) → out/sweep.json
  ../.venv/bin/python exp5.py sweep2                         # стадия 2 (Δτ_θ ≫ Δτ, неявная плавучесть) → out/sweep2.json
  ../.venv/bin/python exp5.py main                           # s1, s4 × 200/100/50/25 м по выбранным
                                                             #   настройкам → out/main.json (+ истории)
  flock /tmp/heat_ca_gpu.lock ../.venv/bin/python exp5.py timing   # мс/раунд и мс/шаг автомата → out/timing.json
  ../.venv/bin/python figs5.py                               # картинки и таблицы

Ошибка — как в опытах 1–4: ‖a − b‖₂/‖b‖₂ по воздушным клеткам (центры клеток), отдельно w, u, θ′.
Два эталона: «8 ч шагов» (out/ref8h, как просил координатор) и точная неподвижная точка автомата
(out/fixed — сошедшиеся прогонки, проверенные самим автоматом: за 2 ч с неё поле не уходит).
"""
from __future__ import annotations

import json
import math
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from adi5 import ADI5  # noqa: E402

OUT = os.path.join(HERE, "out")
NAMES = ["s1_sun_one_slope", "s4_inversion"]
CELLS = [200.0, 100.0, 50.0, 25.0]
THR = (0.05, 0.02, 0.01)

# Проходов прогонки по теплу на раунд: на мелкой сетке неявное тепло с крупным псевдошагом —
# почти эллиптическая задача (κ·Δτ_θ/d² ≫ 1), прогонки по линиям гасят её длинные моды медленно.
HEAT_IT = {200.0: 3, 100.0: 3, 50.0: 6, 25.0: 10}


def config(cname, cell):
    hi = HEAT_IT.get(cell, 10)
    base = dict(heat_iters=hi, mom_iters=3)
    if cname == "implicit_steps":
        # раунд = неявный шаг по времени Δτ = 100 с для всего (тепло, импульс, масса — прогонками,
        # давление — многоуровневые прогонки): раундов ≈ время установления / Δτ
        return dict(base, dtau=100.0, dtau_h=100.0, p_mode="lmg", p_iters=2)
    if cname == "lines_mg":
        # крупный псевдошаг тепла (4000 с ≈ τ/2) + малый импульса (20 с) + неявная плавучесть
        # (дополнение Шура по связи w ↔ θ); давление — многоуровневые прогонки (линии на d, 2d, 4d, …)
        return dict(base, dtau=20.0, dtau_h=4000.0, schur="ph", p_mode="lmg", p_iters=2)
    if cname == "lines_adi":
        # то же, давление — ОДИН уровень: Писмен–Рэчфорд, 8 пар прогонок со сдвигами на раунд
        return dict(base, dtau=20.0, dtau_h=4000.0, schur="ph", p_mode="adi", p_iters=8)
    raise KeyError(cname)


CONFIGS = ["implicit_steps", "lines_mg", "lines_adi"]


def rel(a, b, ok):
    return float(np.linalg.norm((a - b)[ok]) / max(np.linalg.norm(b[ok]), 1e-30))


def load_refs(name, cell):
    r8 = np.load(os.path.join(OUT, "ref8h", f"{name}_{cell:g}.npz"))
    fx = np.load(os.path.join(OUT, "fixed", f"{name}_{cell:g}.npz"))
    old = np.load(os.path.join(os.path.dirname(HERE), "out", "refs", f"{name}_{cell:g}.npz"))
    return dict(r8=r8["c8"], fixed=fx["c"], old=np.stack([old["uc"], old["wc"], old["th"]])), ~r8["solid"]


def run_case(name, cell, cfg, max_rounds=1500, every=5, stop_at=0.002):
    refs, ok = load_refs(name, cell)
    a = ADI5(name, cell, **cfg)
    a.capture()
    hist = []          # (раунд, [w,u,θ′] vs 8ч, vs неподвижной, vs старого эталона)
    hit = {k: {} for k in refs}
    while a.rounds < max_rounds:
        for _ in range(every):
            a.step()
        c = np.stack(a.centers())
        row = [a.rounds]
        for k, ref in refs.items():
            e = [rel(c[1], ref[1], ok), rel(c[0], ref[0], ok), rel(c[2], ref[2], ok)]
            row.append(e)
            for thr in THR:
                for j, nm in enumerate(("w", "u", "th")):
                    key = f"{nm}<{thr:g}"
                    if e[j] < thr and key not in hit[k]:
                        hit[k][key] = a.rounds
                key = f"all<{thr:g}"
                if max(e) < thr and key not in hit[k]:
                    hit[k][key] = a.rounds
        hist.append(row)
        ef = max(row[2])
        if not math.isfinite(ef) or ef > 50:
            break
        if ef < stop_at and max(row[1]) < 0.02:
            break
    return dict(name=name, cell=cell, cfg=cfg, rounds=a.rounds, hist=hist, hit=hit,
                final=dict(zip(refs.keys(), hist[-1][1:])), nx=a.m.nx, nz=a.m.nz,
                cells=int((~a.m.solid_np).sum()), dt_automaton=a.m.dt)


def cmd_sweep2(args):
    """Стадия 2 подбора: разные псевдошаги тепла и импульса, неявная плавучесть."""
    cases = [(n, c) for c in (100.0, 25.0) for n in NAMES]
    grid = []
    for dt, dth in ((100, 100), (120, 600), (120, 1200), (60, 1200), (40, 4000), (30, 4000), (20, 4000)):
        for hi in sorted({3, None}, key=str):
            grid.append((dt, dth, hi))
    path = os.path.join(OUT, "sweep2.json")
    res = json.load(open(path)) if os.path.exists(path) else []
    done = {(r["name"], r["cell"], json.dumps(r["cfg"], sort_keys=True)) for r in res}
    for name, cell in cases:
        for dt, dth, hi in grid:
            cfg = dict(dtau=float(dt), dtau_h=float(dth), schur="ph", heat_iters=hi or HEAT_IT[cell], mom_iters=3,
                       p_mode="lmg", p_iters=2)
            key = (name, cell, json.dumps(cfg, sort_keys=True))
            if key in done:
                continue
            r = run_case(name, cell, cfg, max_rounds=600, every=5)
            r.pop("hist")
            res.append(r)
            h = r["hit"]["fixed"]
            print(f"{name[:2]} {cell:g} Δτ={dt} Δτ_θ={dth} тепло×{cfg['heat_iters']} → до 5 %: "
                  f"{h.get('all<0.05', '—')}, до 1 %: {h.get('all<0.01', '—')} (итог {max(r['final']['fixed']):.3g})",
                  flush=True)
            json.dump(res, open(path, "w"), indent=0)


def cmd_sweep(args):
    """Стадия 1 подбора (исторически первая; Δτ одинаковый для тепла и импульса)."""
    cases = [("s1_sun_one_slope", 100.0), ("s4_inversion", 100.0), ("s1_sun_one_slope", 25.0), ("s4_inversion", 25.0)]
    if args:
        cases = [(args[i], float(args[i + 1])) for i in range(0, len(args), 2)]
    grid = []
    for dtau in (100.0, 150.0, 200.0, 300.0, 400.0):
        for pm, pit in (("lmg", 2), ("adi", 8), ("mg", 2)):
            grid.append(dict(dtau=dtau, dtau_h=dtau, heat_iters=3, mom_iters=3, p_mode=pm, p_iters=pit))
    for dtau in (150.0, 300.0, 600.0):
        grid.append(dict(dtau=dtau, dtau_h=dtau, heat_iters=3, mom_iters=3, p_mode="lmg", p_iters=2, schur=True))
        grid.append(dict(dtau=dtau, dtau_h=dtau, heat_iters=3, mom_iters=3, p_mode="lmg", p_iters=2, schur=True,
                         cfl_loc=1.0))
    for hi in (1, 2):
        grid.append(dict(dtau=150.0, dtau_h=150.0, heat_iters=hi, mom_iters=hi, p_mode="lmg", p_iters=2))
    grid.append(dict(dtau=150.0, dtau_h=150.0, heat_iters=3, mom_iters=3, p_mode="lmg", p_iters=1))
    path = os.path.join(OUT, "sweep.json")
    res = json.load(open(path)) if os.path.exists(path) else []
    done = {(r["name"], r["cell"], json.dumps(r["cfg"], sort_keys=True)) for r in res}
    for name, cell in cases:
        for cfg in grid:
            key = (name, cell, json.dumps(cfg, sort_keys=True))
            if key in done:
                continue
            r = run_case(name, cell, cfg, max_rounds=800, every=5)
            r.pop("hist")
            res.append(r)
            h = r["hit"]["fixed"]
            print(f"{name[:2]} {cell:g} {cfg} → до 5 %: {h.get('all<0.05', '—')}, до 1 %: {h.get('all<0.01', '—')} "
                  f"(итог {max(r['final']['fixed']):.3g})", flush=True)
            json.dump(res, open(path, "w"), indent=0)


def cmd_main(args):
    cfgs = args or CONFIGS
    path = os.path.join(OUT, "main.json")
    res = json.load(open(path)) if os.path.exists(path) else {}
    for cname in cfgs:
        for name in NAMES:
            for cell in CELLS:
                r = run_case(name, cell, config(cname, cell), max_rounds=2000, every=5)
                res[f"{cname}|{name}|{cell:g}"] = r
                h8, hf = r["hit"]["r8"], r["hit"]["fixed"]
                print(f"{cname} {name[:2]} {cell:g} м: vs 8 ч — 5 %: {h8.get('all<0.05', '—')}, 1 %: "
                      f"{h8.get('all<0.01', '—')}; vs неподвижной — 5 %: {hf.get('all<0.05', '—')}, 1 %: "
                      f"{hf.get('all<0.01', '—')}", flush=True)
                json.dump(res, open(path, "w"))


def time_rounds(name, cell, cfg, n=200):
    a = ADI5(name, cell, **cfg)
    a.capture()
    for _ in range(20):
        a.step()
    a.m.sync()
    t0 = time.perf_counter()
    for _ in range(n):
        a.step()
    a.m.sync()
    ms = (time.perf_counter() - t0) / n * 1e3
    pool = a._pool.total_bytes() / 2**20
    import cupy as cp
    return ms, pool + cp.get_default_memory_pool().total_bytes() / 2**20


def time_automaton(name, cell, n=2000):
    from model import HeatCA, Params, SCENARIOS
    m = HeatCA(SCENARIOS[name], Params(cell=cell))
    m.capture_graph()
    for _ in range(50):
        m.step()
    m.sync()
    t0 = time.perf_counter()
    for _ in range(n):
        m.step()
    m.sync()
    return (time.perf_counter() - t0) / n * 1e3


def cmd_timing(args):
    import cupy as cp
    dev = cp.cuda.runtime.getDeviceProperties(0)["name"].decode()
    out = dict(device=dev, rounds={}, automaton={})
    for cell in CELLS + [12.5, 6.25]:
        name = "s1_sun_one_slope"
        out["automaton"][f"{cell:g}"] = time_automaton(name, cell, n=2000 if cell >= 12.5 else 500)
        for cname in CONFIGS:
            ms, mb = time_rounds(name, cell, config(cname, cell), n=200 if cell >= 25 else 50)
            out["rounds"][f"{cname}|{cell:g}"] = dict(ms=ms, mem_mb=mb)
        print(cell, out["automaton"][f"{cell:g}"], {k: v for k, v in out["rounds"].items() if k.endswith(f"|{cell:g}")},
              flush=True)
    json.dump(out, open(os.path.join(OUT, "timing.json"), "w"), indent=1)


if __name__ == "__main__":
    cmd = sys.argv[1]
    {"sweep": cmd_sweep, "sweep2": cmd_sweep2, "main": cmd_main, "timing": cmd_timing}[cmd](sys.argv[2:])
