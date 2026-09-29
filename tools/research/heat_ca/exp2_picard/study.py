#!/usr/bin/env python3
"""Опыт 2: итерации Пикара против шагов по времени — точность и время на GPU.

  ../.venv/bin/python study.py run [сценарий ...] [--cells 200,100,50,25]   → out/runs/*.npz, out/results.json
  ../.venv/bin/python study.py report                                      → out/*.png, out/tables.md

Для каждого сценария и клетки:
  1. Пикар (picard.Picard, параметры по умолчанию, одинаковые для всех случаев) — итерации до
     остаточной невязки «на полу» float32; каждые 10 итераций — проверка шагом автомата и снимок
     полей. Точка, где невязка впервые < допуска (в 10 раз строже критерия эталона) или
     упёрлась в «пол» float32 (< 10 допусков и не падает), — «решение Пикара»; последнее состояние — «точная неподвижная точка» X*.
  2. Шаги по времени (копия model.py, CUDA Graph) 8 ч модели; каждые 10 мин — ошибка против X*.
     Отмечаем момент, когда сработал бы мягкий критерий эталона (0,02 м/с и 0,03 К за 10 мин).
  3. Дрейф: автомат, запущенный из X*, 2 ч модели — насколько уходит (проверка, что X* — его
     неподвижная точка).
Время — только работа GPU (блоки запусков, с синхронизацией); проверки/снимки — отдельно.
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
from model import SCENARIOS, Params, HeatCA  # noqa: E402
from picard import Picard  # noqa: E402

OUT = os.path.join(HERE, "out")
RUNS = os.path.join(OUT, "runs")
NAMES = ["s1_sun_one_slope", "s2_both_slopes", "s3_wind", "s4_inversion"]
CELLS = [200.0, 100.0, 50.0, 25.0]
CHECK = 10                 # итераций Пикара между проверками
TOL_U, TOL_TH = 3.3e-6, 5e-6
FLOOR_U, FLOOR_TH = 3e-7, 3e-7
MAX_OUTER = 3000
T_TS = 8 * 3600.0          # шаги по времени: 8 ч модели
T_DRIFT = 2 * 3600.0


def rel(a, b, f):
    return float(np.sqrt(np.nansum((a - b)[f] ** 2) / max(np.nansum(b[f] ** 2), 1e-30)))


def errs(fields, ref, f):
    return [rel(fields[i], ref[i], f) for i in range(3)]


def run_picard(name, cell):
    P = Picard(SCENARIOS[name], Params(cell=cell))
    m = P.m
    m.sync()
    tc = time.perf_counter()
    P.capture()                     # компиляция + прогрев (1 итерация, в счёт итераций)
    m.sync()
    t_capture = time.perf_counter() - tc
    snaps, hist = [], []
    gpu = 0.0
    t_check = 0.0
    n_check = 0
    first_ok = None
    status = "max"
    while P.outer < MAX_OUTER:
        m.sync()
        t0 = time.perf_counter()
        P.launch(CHECK)
        m.sync()
        gpu += time.perf_counter() - t0
        t0 = time.perf_counter()
        ru, rt = P.ref_residual()
        m.sync()
        t_check += time.perf_counter() - t0
        n_check += 1
        snaps.append(P.centers())
        hist.append(dict(it=P.outer, gpu=gpu, ru=ru, rt=rt))
        if not (math.isfinite(ru) and math.isfinite(rt)) or ru > 1.0:
            status = "diverged"
            break
        if first_ok is None and ru < TOL_U and rt < TOL_TH:
            first_ok = len(hist) - 1
        # «пол» float32 выше допуска (мелкая клетка + ветер): невязка < 10·допуска и за 10 проверок
        # не упала хотя бы на 30 % — дальше не сойдётся, останавливаемся (правило решателя)
        if (first_ok is None and len(hist) > 10 and ru < 10 * TOL_U and rt < 10 * TOL_TH
                and ru > 0.7 * hist[-11]["ru"]):
            first_ok = len(hist) - 1
        if ru < FLOOR_U and rt < FLOOR_TH:
            status = "floor"
            break
        # «пол» float32: невязка перестала падать за 200 итераций
        if first_ok is not None and len(hist) > first_ok + 20:
            status = "stalled"
            break
    exact = snaps[-1]
    uu, ww, tt, pp = (m.to_np(a) for a in (P.u, P.w, P.th, P.p))
    return P, dict(snaps=snaps, hist=hist, first_ok=first_ok, status=status, t_capture=t_capture,
                   check_ms=t_check / n_check * 1e3, exact=exact, raw=(uu, ww, tt, pp),
                   ms_iter=gpu / max(P.outer - 1, 1) * 1e3)


def drift(P, exact, f):
    """Автомат из X*: 2 ч модели, отклонение от X*."""
    m = P.m
    m.stream.use()
    m.u[...] = P.u
    m.w[...] = P.w
    m.mu[...] = 0
    m.H[...] = (m.tb + P.th) * m.fluidf
    m.p[...] = P.p
    m.graph = None
    m.capture_graph()
    n = int(round(T_DRIFT / m.dt))
    for _ in range(n - 1):
        m.step()
    m.sync()
    uc, wc, th = m.centers()
    return errs((wc, uc, th), (exact[1], exact[0], exact[2]), f)


def run_ts(name, cell, exact, f):
    """Шаги по времени 8 ч: ошибка против X* каждые 10 мин модели, мягкий критерий эталона."""
    pr = Params(cell=cell)
    m = HeatCA(SCENARIOS[name], pr)
    m.capture_graph()
    every = max(1, int(round(pr.check_s / m.dt)))
    nmax = int(math.ceil(T_TS / m.dt))
    gpu = 0.0
    prev = None
    mild = None
    hist = []
    n = 1
    while n < nmax:
        m.sync()
        t0 = time.perf_counter()
        for _ in range(every):
            m.step()
        m.sync()
        gpu += time.perf_counter() - t0
        n += every
        uc, wc, th = m.centers()
        e = errs((wc, uc, th), (exact[1], exact[0], exact[2]), f)
        u, w = m.to_np(m.u), m.to_np(m.w)
        thf = m.to_np(m.H) / (1.0 + m.to_np(m.mu))
        if prev is not None and mild is None:
            dv = max(np.abs(u - prev[0]).max(), np.abs(w - prev[1]).max())
            dT = np.abs(np.where(m.solid_np, 0, thf - prev[2])).max()
            if dv < pr.steady_dv and dT < pr.steady_dT:
                mild = len(hist)
        prev = (u, w, thf)
        hist.append(dict(step=n, t=m.t, gpu=gpu, ew=e[0], eu=e[1], eth=e[2]))
    final = (uc, wc, th)
    return m, dict(hist=hist, mild=mild, final=final, dt=m.dt, ms_step=gpu / n * 1e3)


def main_run(names, cells):
    os.makedirs(RUNS, exist_ok=True)
    rpath = os.path.join(OUT, "results.json")
    results = json.load(open(rpath)) if os.path.exists(rpath) else {}
    import plots
    for name in names:
        for cell in cells:
            key = f"{name}_{cell:g}"
            print(f"== {key}", flush=True)
            P, pc = run_picard(name, cell)
            m = P.m
            f = ~m.solid_np
            ex = pc["exact"]
            exw = (ex[1], ex[0], ex[2])
            ph = pc["hist"]
            for h, s in zip(ph, pc["snaps"]):
                h["ew"], h["eu"], h["eth"] = errs((s[1], s[0], s[2]), exw, f)
            ok = pc["first_ok"]
            sol = pc["snaps"][ok] if ok is not None else pc["snaps"][-1]
            dr = drift(P, ex, f)
            mts, ts = run_ts(name, cell, ex, f)
            # сравнение с сохранённым эталоном и с концом 8 ч
            R = np.load(os.path.join(HERE, "..", "out", "refs", f"{key}.npz"))
            rinfo = json.loads(str(R["info"]))
            ref = (R["uc"], R["wc"], R["th"])
            fin = ts["final"]
            e_sol_ref = errs((sol[1], sol[0], sol[2]), (ref[1], ref[0], ref[2]), f)
            e_sol_8h = errs((sol[1], sol[0], sol[2]), (fin[1], fin[0], fin[2]), f)
            e_ref_ex = errs((ref[1], ref[0], ref[2]), exw, f)
            e_8h_ex = errs((fin[1], fin[0], fin[2]), exw, f)
            e_sol_ex = errs((sol[1], sol[0], sol[2]), exw, f)
            met = {k: plots.metrics(m, *fl) for k, fl in
                   (("picard", sol), ("ref", ref), ("ts8h", fin), ("exact", ex))}
            # время Пикара до допуска: итерации + проверки (каждые CHECK итераций)
            t_iter = ph[ok]["gpu"] if ok is not None else float("nan")
            n_chk = ok + 1 if ok is not None else len(ph)
            t_pic = t_iter + n_chk * pc["check_ms"] / 1e3

            def t_to(hist, key_e, thr, tkey="gpu"):
                for h in hist:
                    if h[key_e] <= thr:
                        return h[tkey]
                return float("nan")
            th_ = ts["hist"]
            mild = ts["mild"]
            res = dict(
                scenario=name, cell=cell, nx=m.nx, nz=m.nz, air=int(f.sum()), dt=ts["dt"],
                picard=dict(status=pc["status"], outer_ok=ph[ok]["it"] if ok is not None else None,
                            outer_floor=ph[-1]["it"], t_iter=t_iter, t_total=t_pic,
                            check_ms=pc["check_ms"], ms_iter=pc["ms_iter"], t_capture=pc["t_capture"],
                            ru=ph[ok]["ru"] if ok is not None else ph[-1]["ru"],
                            inner=dict(heat_sweeps=P.heat_sweeps, mom_sweeps=P.mom_sweeps,
                                       p_cycles=P.p_cycles, mg_levels=len(P.poisson.levels)),
                            t_w5=t_to(ph, "ew", 0.05), t_w1=t_to(ph, "ew", 0.01),
                            final_floor_ru=ph[-1]["ru"], final_floor_rt=ph[-1]["rt"]),
                ts=dict(ms_step=ts["ms_step"],
                        mild_step=th_[mild]["step"] if mild is not None else None,
                        mild_t=th_[mild]["t"] if mild is not None else None,
                        mild_gpu=th_[mild]["gpu"] if mild is not None else None,
                        mild_err=[th_[mild][k] for k in ("ew", "eu", "eth")] if mild is not None else None,
                        t_w5=t_to(th_, "ew", 0.05), t_w1=t_to(th_, "ew", 0.01),
                        model_t_w1=t_to(th_, "ew", 0.01, "t"),
                        err_8h=e_8h_ex, gpu_8h=th_[-1]["gpu"]),
                ref_saved=dict(steady_step=rinfo["steady_step"], steady_wall=rinfo["steady_wall"],
                               ms_step=rinfo["ms_step"]),
                err=dict(sol_vs_ref=e_sol_ref, sol_vs_8h=e_sol_8h, ref_vs_exact=e_ref_ex,
                         ts8h_vs_exact=e_8h_ex, sol_vs_exact=e_sol_ex, drift2h=dr),
                metrics=met,
                pic_hist=[{k: h[k] for k in ("it", "gpu", "ru", "rt", "ew", "eu", "eth")} for h in ph],
                ts_hist=th_,
            )
            results[key] = res
            np.savez_compressed(os.path.join(RUNS, f"{key}.npz"),
                                pic_uc=sol[0], pic_wc=sol[1], pic_th=sol[2],
                                ex_uc=ex[0], ex_wc=ex[1], ex_th=ex[2],
                                ts8_uc=fin[0], ts8_wc=fin[1], ts8_th=fin[2],
                                u=pc["raw"][0], w=pc["raw"][1], thp=pc["raw"][2], p=pc["raw"][3])
            json.dump(results, open(rpath, "w"), indent=1, default=float)
            p = res["picard"]
            print(f"   Пикар: {p['outer_ok']} итераций, {p['t_total']:.3f} с (итерации {p['t_iter']:.3f}), "
                  f"{p['ms_iter']:.2f} мс/итер, пол {p['outer_floor']} ({p['status']}); "
                  f"шаги: мягкий критерий {res['ts']['mild_step']} шагов {res['ts']['mild_gpu']:.2f} с, "
                  f"до 1 % по w {res['ts']['t_w1']:.2f} с; ошибка Пикар/эталон w {e_sol_ref[0]:.3f}, "
                  f"Пикар/8 ч w {e_sol_8h[0]:.4f}, дрейф 2 ч w {dr[0]:.4f}", flush=True)
            del P, mts
            import cupy as cp
            cp.get_default_memory_pool().free_all_blocks()


def main_throughput():
    """Пропускная способность на больших сетках (только время, без сходимости): мс на итерацию
    Пикара и на шаг автомата → нс на клетку. Прогонка блоком на линию ограничена 1024 точками
    (линии u — nx+1), поэтому Пикар — до 12,5 м; шаги — до 3,125 м."""
    out = {}
    name = "s1_sun_one_slope"
    for cell in (25.0, 12.5, 6.25, 3.125):
        m = HeatCA(SCENARIOS[name], Params(cell=cell))
        m.capture_graph()
        m.sync()
        n = 200
        t0 = time.perf_counter()
        for _ in range(n):
            m.step()
        m.sync()
        ms_step = (time.perf_counter() - t0) / n * 1e3
        air = int((~m.solid_np).sum())
        r = dict(cell=cell, air=air, ms_step=ms_step, ns_step=ms_step * 1e6 / air)
        del m
        if cell >= 12.5:
            P = Picard(SCENARIOS[name], Params(cell=cell))
            P.capture()
            P.m.sync()
            t0 = time.perf_counter()
            P.launch(n)
            P.m.sync()
            r["ms_iter"] = (time.perf_counter() - t0) / n * 1e3
            r["ns_iter"] = r["ms_iter"] * 1e6 / air
            del P
        import cupy as cp
        cp.get_default_memory_pool().free_all_blocks()
        out[f"{cell:g}"] = r
        print(r, flush=True)
    json.dump(out, open(os.path.join(OUT, "throughput.json"), "w"), indent=1)


if __name__ == "__main__":
    args = sys.argv[1:]
    cmd = args[0] if args else "run"
    cells = CELLS
    if "--cells" in args:
        i = args.index("--cells")
        cells = [float(c) for c in args[i + 1].split(",")]
        args = args[:i] + args[i + 2:]
    names = [a for a in args[1:] if not a.startswith("-")] or NAMES
    if cmd == "run":
        main_run(names, cells)
    elif cmd == "throughput":
        main_throughput()
    elif cmd == "report":
        import report
        report.main()
