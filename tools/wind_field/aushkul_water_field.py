#!/usr/bin/env python3
"""AM-10 (дополнение К0): быстрое поле у Аушкуля (старт ridge_west, озеро Аушкуль рядом) для
скриншота травы/воды по полю — бровка/долина/ветровая тень в одном кадре. Не эталон AM-01
(тот считает `ref_study.py aushkul` — полная сетка ветров/высот, минуты); здесь один случай
(400 м область → окно 100 м, с нагревом и без — для w_mech/w_conv, как для Каянчи) —
достаточно для одной картинки, не для приёмки физики. `to_game_field.py` не подходит напрямую
(старт в нём захардкожен на Каянчу) — формат `WindField.load_file` (AM-05) собран здесь.

Использование (под flock /tmp/heat_ca_gpu.lock, .venv — tools/research/heat_ca/.venv):
    cd tools/research/air3d
    ../heat_ca/.venv/bin/python ../../wind_field/aushkul_water_field.py [--U 3] [--wdir 273] [--hour 12]
Пишет fields/game/aushkul_w100_U<U>.json/.bin (формат WindField, AM-05), вне git.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "research" / "air3d"))

import numpy as np  # noqa: E402
import real as R  # noqa: E402

HERE = Path(__file__).resolve().parent.parent / "research" / "air3d"
LOC = "aushkul"
Z0 = 0.1  # шероховатость решателя (solver.Params.z0) — как в to_game_field.py


def solve(S, max_outer=3000):
    import cupy as cp

    cp.cuda.Device().synchronize()
    if S.nest is not None:
        S.init_nest()
    else:
        S.init_background()
    st = S.solve(max_outer=max_outer, verbose=True, tol_mom=2e-5, tol_th=5e-7, tol_div=1e-6)
    print(f"  {S.g.dx:g} м: {st}, {S.outer} итераций, {S.wall - S.t_check:.2f} с")
    return st


def one_window(dx_dom, dx_win, hour, U10, wdir, heat, center=None):
    g, hc = R.grid_domain(LOC, dx_dom)
    c = R.case(LOC, g, hc, hour, U10, wdir, heat=heat)
    D = R.make(LOC, g, hc, c)
    solve(D)
    gw, hcw = R.grid_window(LOC, dx_win, n=64, center=center)
    cw = R.case(LOC, gw, hcw, hour, U10, wdir, heat=heat)
    W = R.make(LOC, gw, hcw, cw, parent=D)
    solve(W)
    W.finalize()
    return W


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--U", type=float, default=3.0)
    ap.add_argument("--wdir", type=float, default=273.0)
    ap.add_argument("--hour", type=float, default=12.0)
    ap.add_argument("--dx-dom", type=float, default=400.0)
    ap.add_argument("--dx-win", type=float, default=100.0)
    ap.add_argument("--cx", type=float, default=None, help="центр окна x (по умолчанию — старт)")
    ap.add_argument("--cy", type=float, default=None, help="центр окна y (по умолчанию — старт)")
    args = ap.parse_args()

    t0 = time.perf_counter()
    print(
        f"aushkul_water_field: {LOC}/{R.START[LOC]}, U={args.U:g}, wdir={args.wdir:g}, "
        f"hour={args.hour:g}"
    )
    center = (args.cx, args.cy) if args.cx is not None and args.cy is not None else None
    print("с нагревом:")
    Wh = one_window(args.dx_dom, args.dx_win, args.hour, args.U, args.wdir, True, center)
    print("без нагрева:")
    Wn = one_window(args.dx_dom, args.dx_win, args.hour, args.U, args.wdir, False, center)

    for k in ("dx", "dz", "x0", "y0", "z_bot", "nx", "ny", "nz"):
        assert getattr(Wh.g, k) == getattr(Wn.g, k), ("разные сетки heat/noheat", k)

    u, v, w, th = Wh.centers()
    _, _, w_mech, _ = Wn.centers()
    ch = dict(
        u=np.nan_to_num(u), v=np.nan_to_num(v),
        w_mech=np.nan_to_num(w_mech), w_conv=np.nan_to_num(w - w_mech),
        theta=np.nan_to_num(th),
    )
    hc = Wh.hc

    suffix = "lake" if center is not None else "ridge_west"
    out = HERE / "fields" / "game" / f"aushkul_{suffix}_w{int(args.dx_win)}_U{args.U:g}"
    out.parent.mkdir(parents=True, exist_ok=True)
    parts, arrays, off = [], {}, 0
    for name, a in list(ch.items()) + [("hc", hc)]:
        a = np.ascontiguousarray(a.astype("<f4")).ravel()
        arrays[name] = [off, int(a.size)]
        parts.append(a)
        off += a.size
    np.concatenate(parts).tofile(str(out) + ".bin")
    js = dict(
        format="deltaplan-air-field", version=1,
        dx=Wh.g.dx, dz=Wh.g.dz, x0=Wh.g.x0, y0=Wh.g.y0, z_bot=Wh.g.z_bot,
        nx=Wh.g.nx, ny=Wh.g.ny, nz=Wh.g.nz, z0=Z0,
        layout="(nz, ny, nx), индекс (k·ny + j)·nx + i; i — восток, j — север (−Z игры), k — вверх",
        source=["aushkul_water_field.py (не эталон AM-01, один случай для скриншота)"],
        cond=dict(hour=args.hour, wind=args.U, wdir=args.wdir, loc=LOC, site=R.START[LOC]),
        probes=[], arrays=arrays,
    )
    Path(str(out) + ".json").write_text(json.dumps(js, ensure_ascii=False, indent=1))
    print(f"aushkul_water_field: {out}.json/.bin за {time.perf_counter() - t0:.1f} с")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
