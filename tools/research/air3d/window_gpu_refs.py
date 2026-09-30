"""Эталоны окон клипмапа для GPU (AM-04): окно 100 м от области 400 м и окно 50 м от окна 100 м
у старта Каянча (Онгудай, 12:00, ветер с 150°) — `air.py`, граничные условия окна от родителя
(reference.md → «Граничные условия области»: трилинейно из родителя, поправка потока Σ = 0,
зона релаксации).

Для каждого окна — вход (рельеф hc, поток тепла H, dθ̄/dz по уровням окна, z_i, сетка), итерации
эталона (float64 и float32) для ветра 3 и 6 м/с (окно 50 м — 3 м/с) с нагревом и без (окно без
нагрева — от родителя без нагрева, как в игре), решение float64 в 16 × 16 столбцах у старта и 8 × 8
у западного края окна (центры клеток: u, v, w_mech, w_conv, θ′), грани u западной границы после
поправки потока, поправка потока, баланс тепла, СКО ∇·u и выборка как в игре над стартом.
GPU-тест сам решает родителя (область 400 м по фикстуре `picard/`), затем окна.

Формат — как `picard_gpu_refs.py` (float32 LE .bin + .json со смещениями).

    PY=../heat_ca/.venv/bin/python
    flock /tmp/heat_ca_gpu.lock $PY window_gpu_refs.py  # → tests/atmosphere/fixtures/air_model/window/
"""
from __future__ import annotations

import time
from pathlib import Path

import numpy as np

import air as A
import real as R
import to_game_field as TG
from picard_gpu_refs import Pack

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "tests/atmosphere/fixtures/air_model/window"
LOC = "ongudai"
HOUR = 12.0
WDIR = 150.0
TOL = dict(tol_mom=2e-5, tol_th=5e-7, tol_div=1e-6)
N_START = 16
N_EDGE = 8


def domain(U, heat, dtype):
    g, hc = R.grid_domain(LOC, 400)
    c = R.case(LOC, g, hc, HOUR, U, WDIR, heat=heat)
    S = R.make(LOC, g, hc, c, dtype=dtype)
    S.init_background()
    st = S.solve(max_outer=3000, **TOL)
    S.finalize()
    return S, st


def window(parent, dx, U, heat, dtype):
    g, hc = R.grid_window(LOC, dx, n=64)
    c = R.case(LOC, g, hc, HOUR, U, WDIR, heat=heat)
    S = R.make(LOC, g, hc, c, parent=parent, dtype=dtype)
    S.init_nest()
    st = S.solve(max_outer=3000, **TOL)
    S.finalize()
    return S, st


def div_rms(S):
    d = np.asarray(S.divergence().get())[S.fluid_np[1:-1, 1:-1, 1:-1]]
    return float(np.sqrt(np.mean(np.square(d))))


def crops(P, SH, SN, tag):
    """Центры клеток решения с нагревом и без в столбцах у старта и у западного края."""
    g = SH.g
    u, v, w, th = SH.centers()
    _, _, wn, _ = SN.centers()
    ch = {k: np.nan_to_num(a) for k, a in dict(u=u, v=v, w_mech=wn, w_conv=w - wn, theta=th).items()}
    site = R.location(LOC).sites[R.START[LOC]]
    i0 = int((site["x"] - g.x0) / g.dx) - N_START // 2
    j0 = int((site["y"] - g.y0) / g.dx) - N_START // 2
    e0 = g.ny // 2 - N_EDGE // 2
    for k, a in ch.items():
        P.add(f"{tag}start_{k}", a[:, j0:j0 + N_START, i0:i0 + N_START])
        P.add(f"{tag}edge_{k}", a[:, e0:e0 + N_EDGE, 0:N_EDGE])
    return ch, dict(i0=i0, j0=j0, n=N_START), dict(i0=0, j0=e0, n=N_EDGE)


def probes(ch, S):
    g = S.g
    site = R.location(LOC).sites[R.START[LOC]]
    sx, sy = site["x"], site["y"]
    gg = dict(dx=g.dx, dz=g.dz, x0=g.x0, y0=g.y0, z_bot=g.z_bot, nx=g.nx, ny=g.ny, nz=g.nz)
    _, hg = TG.game_sample(ch, S.hc, gg, TG.Z0, sx, sy, 0.0)
    out = []
    for agl in (10.0, 50.0, 150.0, 400.0):
        fs, _ = TG.game_sample(ch, S.hc, gg, TG.Z0, sx, sy, hg + agl)
        out.append(dict(agl=agl, game=[sx, hg + agl, -sy], field=fs))
    return out


def write_window(name, S, runs, extra, P):
    g, c = S.g, S.case
    NZ = g.nz + 2
    zc = g.z_bot + (np.arange(NZ) - 0.5) * g.dz
    site = R.location(LOC).sites[R.START[LOC]]
    # params — параметры, отличные от умолчаний AirCase, с которыми посчитан эталон (тест берёт их
    # отсюда, как у picard_gpu_refs.py)
    meta = dict(loc=LOC, hour=HOUR, wdir=WDIR, dtau_u=A.Params().dtau_per_m * g.dx,
                params=dict(lam_frac=A.Params().lam_frac, pr_t=A.Params().pr_t, k_relax=A.Params().k_relax), dx=g.dx, dz=g.dz,
                nx=g.nx, ny=g.ny, nz=g.nz, z_bot=g.z_bot, x0=g.x0, y0=g.y0, z_i=c.z_i,
                site=dict(x=site["x"], y=site["y"]), runs=runs, **extra)
    P.add("hc", S.hc)
    P.add("gam", c.gam(zc))
    P.write(OUT / name, meta)
    print("→", OUT / name, flush=True)


def main():
    import cupy as cp
    OUT.mkdir(parents=True, exist_ok=True)
    P100, P50 = Pack(), Pack()
    runs100, runs50, ex100, ex50 = [], [], dict(winds={}), dict(winds={})
    H100 = H50 = None
    for U in (3.0, 6.0):
        par = {}
        for heat in (True, False):
            for dtype in (np.float32, np.float64):
                t0 = time.perf_counter()
                D, sd = domain(U, heat, dtype)
                W, sw = window(D, 100, U, heat, dtype)
                runs100.append(dict(U10=U, heat=heat, dtype=np.dtype(dtype).name, status=sw, iters=W.outer,
                                    parent_iters=D.outer, parent_status=sd, t_cupy=round(W.wall - W.t_check, 3),
                                    nest_corr=float(W.nest_corr)))
                print("w100", U, heat, np.dtype(dtype).name, sd, D.outer, sw, W.outer,
                      round(time.perf_counter() - t0, 1), flush=True)
                if dtype == np.float64:
                    par[heat] = (D, W)
                else:
                    del D, W
                cp.get_default_memory_pool().free_all_blocks()
        (_, WH), (_, WN) = par[True], par[False]
        tag = f"U{int(U)}_"
        ch, cs, ce = crops(P100, WH, WN, tag)
        # грани u западной границы окна (i = 1, после поправки потока) — решение с нагревом
        P100.add(tag + "west_u", WH.u.get()[:, :, 1])
        if H100 is None:
            H100 = WH.case.H
        ex100["winds"][tag] = dict(crop_start=cs, crop_edge=ce, probes=probes(ch, WH),
                                   u_scale=float(np.nanmax(np.sqrt(ch["u"] ** 2 + ch["v"] ** 2))),
                                   div_rms=[div_rms(WH), div_rms(WN)], heat_budget=WH.heat_budget(),
                                   nest_corr=[float(WH.nest_corr), float(WN.nest_corr)])
        if U == 3.0:
            # окно 50 м от окна 100 м (float64 и float32 — родитель той же точности)
            p50 = {}
            for heat in (True, False):
                W5, s5 = window(par[heat][1], 50, U, heat, np.float64)
                runs50.append(dict(U10=U, heat=heat, dtype="float64", status=s5, iters=W5.outer,
                                   nest_corr=float(W5.nest_corr)))
                print("w50", U, heat, "float64", s5, W5.outer, flush=True)
                p50[heat] = W5
            ch5, cs5, ce5 = crops(P50, p50[True], p50[False], tag)
            H50 = p50[True].case.H
            ex50["winds"][tag] = dict(crop_start=cs5, crop_edge=ce5, probes=probes(ch5, p50[True]),
                                      u_scale=float(np.nanmax(np.sqrt(ch5["u"] ** 2 + ch5["v"] ** 2))),
                                      div_rms=[div_rms(p50[True]), div_rms(p50[False])],
                                      heat_budget=p50[True].heat_budget())
            W50m = p50[True]
            for heat in (True, False):
                D, _ = domain(U, heat, np.float32)
                W1, _ = window(D, 100, U, heat, np.float32)
                W5, s5 = window(W1, 50, U, heat, np.float32)
                runs50.append(dict(U10=U, heat=heat, dtype="float32", status=s5, iters=W5.outer,
                                   t_cupy=round(W5.wall - W5.t_check, 3)))
                print("w50", U, heat, "float32", s5, W5.outer, flush=True)
                del D, W1, W5
                cp.get_default_memory_pool().free_all_blocks()
        W100m = WH
        del par
        cp.get_default_memory_pool().free_all_blocks()
    P100.add("H", H100)
    P50.add("H", H50)
    write_window("ongudai_w100_h12", W100m, runs100, ex100, P100)
    write_window("ongudai_w50_h12", W50m, runs50, ex50, P50)


if __name__ == "__main__":
    main()
