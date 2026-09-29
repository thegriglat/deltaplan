#!/usr/bin/env python3
"""Эталон AM-01 на реальном рельефе: сходимость (ветер × клетка), окна, библиотека, погода, вечер,
фоновый пересчёт, Аушкуль, 2-й порядок переноса, float32 против float64.

  ../heat_ca/.venv/bin/python ref_study.py cells     → out/ref/cells.json     (0/3/6/8 м/с × 400/200/100/50 м)
  ../heat_ca/.venv/bin/python ref_study.py windows   → out/ref/windows.json   (почему окна сходятся медленнее)
  ../heat_ca/.venv/bin/python ref_study.py library   → out/ref/library.json   (ближайшее поле / смесь против точного)
  ../heat_ca/.venv/bin/python ref_study.py weather   → out/ref/weather.json   (классы погоды)
  ../heat_ca/.venv/bin/python ref_study.py hours     → out/ref/hours.json     (9/12/15/20, вечер, пересчёт 15 мин)
  ../heat_ca/.venv/bin/python ref_study.py aushkul   → out/ref/aushkul.json
  ../heat_ca/.venv/bin/python ref_study.py adv       → out/ref/adv.json       (1-й против 2-го порядка)
  ../heat_ca/.venv/bin/python ref_study.py precision → out/ref/precision.json (float32 против float64)
Все замеры времени — под flock /tmp/heat_ca_gpu.lock.
"""
from __future__ import annotations

import json
import math
import sys
import time

import numpy as np

import air as A
import real as R
import synth as SY

OUT = SY.OUT
FIELDS = SY.HERE / "fields"
FIELDS.mkdir(exist_ok=True)
LOC = "ongudai"
WDIR = 150.0            # в лоб старту Каянчи (курс разбега 151°)
TOL = dict(tol_mom=2e-5, tol_th=5e-7, tol_div=1e-6)
MAXIT = 3000


def solve(S, warm=None, with_p=True, max_outer=MAXIT, verbose=False):
    import cupy as cp
    cp.cuda.Device().synchronize()
    t0 = time.perf_counter()
    if warm is not None:
        S.init_from(warm, with_p=with_p)
    elif S.nest is not None:
        S.init_nest()
    else:
        S.init_background()
    cp.cuda.Device().synchronize()
    t_init = time.perf_counter() - t0
    st = S.solve(max_outer=max_outer, verbose=verbose, **TOL)
    return dict(status=st, iters=S.outer, t_solve=round(S.wall - S.t_check, 3), t_init=round(t_init, 3),
                mem_mb=round(S.mem_mb()), last=S.hist[-1] if S.hist else None)


def finalize_stats(S):
    S.finalize()
    d = S.divergence()
    import cupy as cp
    div_rms = float(cp.sqrt(cp.sum(d * d) / S.n_fluid))
    div_max = float(cp.max(cp.abs(d)))
    Uref = max(S.U_a, 1.0)
    hb = S.heat_budget()
    return dict(div_rms=div_rms, div_max=div_max, div_rel=div_rms * S.dx / Uref, heat=hb)


def fields(S):
    return S.centers()


def relerr(F, Rf, mask=None):
    out = {}
    for n, f, r in zip(("u", "v", "w", "th"), F, Rf):
        m = ~(np.isnan(f) | np.isnan(r))
        if mask is not None:
            m &= mask
        out[n] = dict(rel=float(np.sqrt(np.sum((f - r)[m] ** 2) / max(np.sum(r[m] ** 2), 1e-30))),
                      max=float(np.max(np.abs(f - r)[m])))
    return out


def low_mask(S, agl_max=600.0):
    """Клетки воздуха до agl_max над рельефом (где летает пилот)."""
    g = S.g
    z = g.z_bot + (np.arange(g.nz) + 0.5) * g.dz
    return (z[:, None, None] - S.hc[None]) < agl_max


def domain(dx, hour, U10, wdir=WDIR, heat=True, t_max=None, sky="clear", prm=None, dtype=np.float32):
    g, hc = R.grid_domain(LOC, dx)
    c = R.case(LOC, g, hc, hour, U10, wdir, t_max, sky, heat)
    return R.make(LOC, g, hc, c, prm=prm, dtype=dtype)


def window(parent, dx, hour, U10, wdir=WDIR, heat=True, t_max=None, sky="clear", prm=None, n=64, dtype=np.float32):
    g, hc = R.grid_window(LOC, dx, n=n)
    c = R.case(LOC, g, hc, hour, U10, wdir, t_max, sky, heat)
    return R.make(LOC, g, hc, c, parent=parent, prm=prm, dtype=dtype)


def free(*objs):
    import cupy as cp
    import gc
    for o in objs:
        if hasattr(o, "release"):
            o.release()
            for k in list(vars(o)):
                if k not in ("g", "case", "prm", "loc", "hc"):
                    setattr(o, k, None)
    gc.collect()
    cp.get_default_memory_pool().free_all_blocks()


# ============================================================================== cells
def cmd_cells(hour=12.0):
    path = OUT / "cells.json"
    res = json.loads(path.read_text()) if path.exists() else dict(hour=hour, wdir=WDIR, rows=[])
    done = {(r["U10"], r["heat"]) for r in res["rows"]}
    for U in (0.0, 3.0, 6.0, 8.0):
        for heat in ((True, False) if U in (3.0, 6.0) else (True,)):
            if (U, heat) in done:
                continue
            row = dict(U10=U, heat=heat)
            D4 = domain(400, hour, U, heat=heat)
            row["d400"] = solve(D4) | dict(key=R.key_numbers(D4), closure=D4.closure_info)
            row["d400"].update(finalize_stats(D4))
            print("d400", U, heat, row["d400"]["status"], row["d400"]["iters"], row["d400"]["t_solve"], flush=True)
            if heat:
                D2 = domain(200, hour, U, heat=heat)
                row["d200"] = solve(D2) | dict(key=R.key_numbers(D2))
                row["d200"].update(finalize_stats(D2))
                print("d200", U, row["d200"]["status"], row["d200"]["iters"], row["d200"]["t_solve"], flush=True)
                free(D2)
            W1 = window(D4, 100, hour, U, heat=heat)
            row["w100"] = solve(W1) | dict(key=R.key_numbers(W1))
            row["w100"].update(finalize_stats(W1))
            print("w100", U, heat, row["w100"]["status"], row["w100"]["iters"], row["w100"]["t_solve"], flush=True)
            if heat:
                W5 = window(W1, 50, hour, U, heat=heat)
                row["w50"] = solve(W5) | dict(key=R.key_numbers(W5))
                row["w50"].update(finalize_stats(W5))
                print("w50", U, row["w50"]["status"], row["w50"]["iters"], row["w50"]["t_solve"], flush=True)
                free(W5)
            free(D4, W1)
            res["rows"].append(row)
            SY.jdump(res, path)


# ============================================================================== windows
def conv_rate(hist):
    """Средний множитель невязки импульса за итерацию на второй половине истории."""
    h = [r for r in hist if r["mom_rms"] > 0]
    if len(h) < 4:
        return None
    a, b = h[len(h) // 2], h[-1]
    return (b["mom_rms"] / a["mom_rms"]) ** (1.0 / max(b["it"] - a["it"], 1))


def cmd_windows(hour=12.0, U=3.0):
    """Гипотезы медленной сходимости окон: (а) граница от родителя, (б) тёплый старт от
    интерполяции, (в) число уровней/V-циклов проекции, (г) анизотропия и клетка (сама физика)."""
    res = dict(hour=hour, U10=U, rows=[])
    path = OUT / "windows.json"
    D4 = domain(400, hour, U)
    solve(D4)
    W1 = window(D4, 100, hour, U)
    solve(W1)

    def add(name, S, r, **kw):
        row = dict(name=name, status=r["status"], iters=r["iters"], t=r["t_solve"], rate=conv_rate(S.hist),
                   mg_levels=len(S.mg.levels), shape=list(S.shape), **kw)
        res["rows"].append(row)
        print(json.dumps(row), flush=True)
        SY.jdump(res, path)
    # базовые окна
    for dx, P in ((100, D4), (50, W1)):
        S = window(P, dx, hour, U)
        add(f"w{dx} base", S, solve(S))
        # (б) холодный старт окна: фон вместо интерполяции родителя (границы — от родителя)
        S2 = window(P, dx, hour, U)
        S2.set_nest_bc(init=True)
        cp = S2.cp
        # внутри — однородный фон U_a по направлению (как холодный старт области)
        S2.u[...] = cp.where(S2.tu == 1, S2.ubg, S2.u); S2.v[...] = cp.where(S2.tv == 1, S2.vbg, S2.v)
        S2.w[...] = cp.where(S2.tw == 1, 0, S2.w); S2.th[...] = cp.where(S2.cell == 1, 0, S2.th)
        S2.p[...] = 0; S2.project(cycles=30); S2.p[...] = 0
        add(f"w{dx} cold-inside", S2, dict(status=S2.solve(max_outer=MAXIT, **TOL), iters=S2.outer, t_solve=S2.wall))
        # (в) больше V-циклов проекции на итерацию
        for vc in (2, 4):
            S3 = window(P, dx, hour, U, prm=A.Params(vcycles=vc))
            add(f"w{dx} vcycles={vc}", S3, solve(S3))
        # (а) граница: окно шире (96×96 и 128×128 клеток) — если медленно из-за границы, итераций
        #     не меньше; если из-за «области влияния» — растёт с размером
        for n in (96, 128):
            S4 = window(P, dx, hour, U, n=n)
            add(f"w{dx} n={n}", S4, solve(S4))
        # (г) та же клетка как вся область (без родителя) — 100 м по области 12,8 км?
        free(S, S2)
    # (д) область с клеткой окна (жёсткие границы, губки), тот же размер 64×64 — для сравнения с окном
    #     (граница от родителя против жёсткой): сетка окна, но условия как у области
    for dx in (100, 50):
        g, hc = R.grid_window(LOC, dx, n=64)
        c = R.case(LOC, g, hc, hour, U, WDIR)
        S5 = R.make(LOC, g, hc, c, prm=A.Params(sponge_side_m=0.15 * 64 * dx))
        add(f"box{dx} rigid+sponge", S5, solve(S5))
        # псевдошаг импульса: больше Δτ (быстрее для штиля) / меньше
        for dt in (600.0, 2 * 0.3 * dx, 0.5 * 0.3 * dx):
            S6 = window(W1 if dx == 50 else D4, dx, hour, U, prm=A.Params(dtau_u=dt))
            add(f"w{dx} dtau_u={dt:g}", S6, solve(S6))
    free(D4, W1)


# ============================================================================== library
def cmd_library(hour=12.0):
    """Ошибка ближайшего поля и смеси двух ближайших против точного: направления (узлы через 45°)
    и силы (узлы 3 и 6 м/с). Цели: середина между узлами (худший случай) и 1/4.
    Мера — отн. L2 и максимум по u, v, w, θ′ до 600 м над землёй; область 400 м и окно 100 м."""
    res = dict(hour=hour, rows=[])
    path = OUT / "library.json"
    cache = {}

    def get(U, d, level):
        key = (U, d % 360, level)
        if key not in cache:
            D = domain(400, hour, U, wdir=d % 360)
            solve(D)
            FD = fields(D)
            W = window(D, 100, hour, U, wdir=d % 360)
            solve(W)
            FW = fields(W)
            cache[(U, d % 360, "d")] = (FD, low_mask(D))
            cache[(U, d % 360, "w")] = (FW, low_mask(W))
            free(D, W)
        return cache[key]

    targets = []
    # направление: узлы 135° и 180°, 3 м/с; цели 157,5° (середина) и 146,25° (четверть)
    for d, frac in ((157.5, 0.5), (146.25, 0.25)):
        targets.append(dict(kind="dir", U=3.0, d=d, nodes=[(3.0, 135.0), (3.0, 180.0)], frac=frac))
        targets.append(dict(kind="dir", U=6.0, d=d, nodes=[(6.0, 135.0), (6.0, 180.0)], frac=frac))
    # сила: узлы 3 и 6 м/с, направление 135°; цели 4,5 (середина) и 3,75
    for U, frac in ((4.5, 0.5), (3.75, 0.25)):
        targets.append(dict(kind="speed", U=U, d=135.0, nodes=[(3.0, 135.0), (6.0, 135.0)], frac=frac))
    # штиль ↔ 3 м/с: 1,5 м/с
    targets.append(dict(kind="speed", U=1.5, d=135.0, nodes=[(0.0, 135.0), (3.0, 135.0)], frac=0.5))
    for t in targets:
        for level in ("d", "w"):
            Fx, m = get(t["U"], t["d"], level)
            A0, _ = get(*t["nodes"][0], level)
            A1, _ = get(*t["nodes"][1], level)
            near = A0 if t["frac"] <= 0.5 else A1
            f = t["frac"]
            mix = [(1 - f) * a + f * b for a, b in zip(A0, A1)]
            row = dict(kind=t["kind"], U=t["U"], d=t["d"], frac=f, level=level,
                       nearest=relerr(near, Fx, m), mix=relerr(mix, Fx, m))
            res["rows"].append(row)
            print(json.dumps(dict(k=t["kind"], U=t["U"], d=t["d"], lvl=level, near_w=row["nearest"]["w"],
                                  near_u=row["nearest"]["u"], mix_w=row["mix"]["w"], mix_u=row["mix"]["u"])), flush=True)
            SY.jdump(res, path)


# ============================================================================== weather
def cmd_weather():
    """Насколько поле меняется между классами погоды: температура дня (типовая ±8 К → z_i),
    облачность (ясно / переменная / пасмурно → поток тепла) против типового ясного дня."""
    res = dict(rows=[])
    path = OUT / "weather.json"
    tm = R.W.typical_max_c(7, 15)
    for hour in (12.0, 15.0):
        for U in (3.0, 6.0):
            ref = {}
            for lvl in ("d", "w"):
                pass
            D = domain(400, hour, U); solve(D); Fd = fields(D); md = low_mask(D)
            W = window(D, 100, hour, U); solve(W); Fw = fields(W); mw = low_mask(W)
            kd, kw = R.key_numbers(D), R.key_numbers(W)
            free(D, W)
            for t_max, sky in ((tm - 8, "clear"), (tm + 8, "clear"), (tm, "partly"), (tm, "overcast")):
                D2 = domain(400, hour, U, t_max=t_max, sky=sky); r1 = solve(D2); F2 = fields(D2)
                W2 = window(D2, 100, hour, U, t_max=t_max, sky=sky); r2 = solve(W2); G2 = fields(W2)
                row = dict(hour=hour, U10=U, t_max=t_max, sky=sky, day=D2.case.day.summary(),
                           d400=relerr(F2, Fd, md), w100=relerr(G2, Fw, mw),
                           key_ref=kw, key=R.key_numbers(W2), iters=[r1["iters"], r2["iters"]])
                res["rows"].append(row)
                print(json.dumps(dict(h=hour, U=U, t=t_max, sky=sky, d_w=row["d400"]["w"], w_w=row["w100"]["w"],
                                      w_u=row["w100"]["u"], th=row["w100"]["th"])), flush=True)
                SY.jdump(res, path)
                free(D2, W2)


# ============================================================================== hours
def cmd_hours():
    """Часы старта 9/12/15/20 (сходимость, картина), вечер 20:00, фоновый пересчёт каждые 15 мин
    (итерации от предыдущего поля с давлением и без) и переход 15 → 20 шагами по 15 мин."""
    res = dict(hours=[], recompute=[])
    path = OUT / "hours.json"
    for U in (0.0, 3.0, 6.0):
        for hour in (9.0, 12.0, 15.0, 20.0):
            D = domain(400, hour, U); rd = solve(D)
            W = window(D, 100, hour, U); rw = solve(W)
            row = dict(U10=U, hour=hour, day=D.case.day.summary(), d400=dict(rd, key=R.key_numbers(D), closure=D.closure_info),
                       w100=dict(rw, key=R.key_numbers(W)), budget=D.heat_budget())
            res["hours"].append(row)
            print(json.dumps(dict(U=U, h=hour, d=[rd["status"], rd["iters"], rd["t_solve"]],
                                  w=[rw["status"], rw["iters"], rw["t_solve"]], key=row["w100"]["key"])), flush=True)
            SY.jdump(res, path)
            if hour == 20.0 and U in (0.0, 3.0):
                np.savez_compressed(FIELDS / f"evening_w100_U{U:g}.npz", **{k: np.float32(v) for k, v in zip("uvwt", fields(W))},
                                    hc=W.hc, dx=W.g.dx, dz=W.g.dz, z_bot=W.g.z_bot, x0=W.g.x0, y0=W.g.y0)
            free(D, W)
    # фоновый пересчёт: шаг 15 игровых минут от предыдущего поля
    for U in (0.0, 3.0, 6.0):
        for h0 in (9.0, 12.0, 15.0, 19.0):
            D = domain(400, h0, U); solve(D); st = D.state()
            W = window(D, 100, h0, U); solve(W); sw = W.state()
            h1 = h0 + 0.25
            D1 = domain(400, h1, U); r_cold = solve(D1); F1 = fields(D1); m1 = low_mask(D1)
            D2 = domain(400, h1, U); r_warm = solve(D2, warm=st, with_p=True)
            D3 = domain(400, h1, U); r_warm_np = solve(D3, warm=st, with_p=False)
            W1c = window(D1, 100, h1, U); r_wc = solve(W1c)
            W1w = window(D2, 100, h1, U); r_ww = solve(W1w, warm=sw, with_p=True)
            row = dict(U10=U, h0=h0, h1=h1, d400=dict(cold=r_cold["iters"], warm_p=r_warm["iters"], warm_nop=r_warm_np["iters"],
                                                      t_cold=r_cold["t_solve"], t_warm=r_warm["t_solve"]),
                       w100=dict(cold=r_wc["iters"], warm_p=r_ww["iters"], t_cold=r_wc["t_solve"], t_warm=r_ww["t_solve"]),
                       change_15min=relerr(fields(D), F1, m1))
            res["recompute"].append(row)
            print(json.dumps({k: v for k, v in row.items() if k != "change_15min"}), flush=True)
            SY.jdump(res, path)
            free(D, W, D1, D2, D3, W1c, W1w)


# ============================================================================== aushkul
def cmd_aushkul(hour=12.0):
    global LOC
    LOC = "aushkul"
    res = dict(rows=[])
    path = OUT / "aushkul.json"
    for U, wdir in ((0.0, 270.0), (3.0, 273.0), (6.0, 273.0), (8.0, 273.0)):
        for heat in (True, False):
            if U == 0 and not heat:
                continue
            D = domain(400, hour, U, wdir=wdir, heat=heat); rd = solve(D)
            W = window(D, 100, hour, U, wdir=wdir, heat=heat); rw = solve(W)
            W5 = window(W, 50, hour, U, wdir=wdir, heat=heat); r5 = solve(W5)
            row = dict(U10=U, wdir=wdir, heat=heat, d400=dict(rd, key=R.key_numbers(D)), w100=dict(rw, key=R.key_numbers(W)),
                       w50=dict(r5, key=R.key_numbers(W5)))
            res["rows"].append(row)
            print(json.dumps(dict(U=U, heat=heat, d=[rd["status"], rd["iters"]], w=[rw["status"], rw["iters"]],
                                  w5=[r5["status"], r5["iters"]], k100=row["w100"]["key"], k50=row["w50"]["key"])), flush=True)
            SY.jdump(res, path)
            if U == 3.0 and heat:
                np.savez_compressed(FIELDS / "aushkul_w50_U3.npz", **{k: np.float32(v) for k, v in zip("uvwt", fields(W5))},
                                    hc=W5.hc, dx=W5.g.dx, dz=W5.g.dz, z_bot=W5.g.z_bot, x0=W5.g.x0, y0=W5.g.y0)
            free(D, W, W5)


# ============================================================================== adv
def cmd_adv(hour=12.0):
    """Перенос 1-го порядка против 2-го (MUSCL/ван Лир): Онгудай 400 + окна 100/50, Аньези 100/50 м."""
    res = dict(rows=[])
    path = OUT / "adv.json"
    for U in (3.0, 6.0):
        F = {}
        for adv2 in (False, True):
            prm = A.Params(adv2=adv2)
            D = domain(400, hour, U, prm=prm); rd = solve(D)
            W = window(D, 100, hour, U, prm=prm); rw = solve(W)
            W5 = window(W, 50, hour, U, prm=prm); r5 = solve(W5)
            F[adv2] = (fields(D), fields(W), fields(W5), low_mask(D), low_mask(W), low_mask(W5))
            res["rows"].append(dict(U10=U, adv2=adv2, iters=[rd["iters"], rw["iters"], r5["iters"]],
                                    t=[rd["t_solve"], rw["t_solve"], r5["t_solve"]],
                                    key=[R.key_numbers(D), R.key_numbers(W), R.key_numbers(W5)]))
            print(json.dumps(res["rows"][-1])[:400], flush=True)
            free(D, W, W5)
        a, b = F[False], F[True]
        res["rows"].append(dict(U10=U, diff_1vs2=dict(d400=relerr(a[0], b[0], b[3]), w100=relerr(a[1], b[1], b[4]),
                                                      w50=relerr(a[2], b[2], b[5]))))
        print(json.dumps(res["rows"][-1]), flush=True)
        SY.jdump(res, path)


# ============================================================================== precision
def cmd_precision(hour=12.0, U=3.0):
    res = {}
    F = {}
    for dt in (np.float32, np.float64):
        D = domain(400, hour, U, dtype=dt); rd = solve(D)
        W = window(D, 100, hour, U, dtype=dt); rw = solve(W)
        F[np.dtype(dt).name] = (fields(D), fields(W), low_mask(D), low_mask(W))
        res[np.dtype(dt).name] = dict(d400=rd["iters"], w100=rw["iters"], t=[rd["t_solve"], rw["t_solve"]])
        free(D, W)
    a, b = F["float32"], F["float64"]
    res["diff"] = dict(d400=relerr(a[0], b[0], b[2]), w100=relerr(a[1], b[1], b[3]))
    print(json.dumps(res), flush=True)
    SY.jdump(res, OUT / "precision.json")


if __name__ == "__main__":
    globals()["cmd_" + sys.argv[1]]()
